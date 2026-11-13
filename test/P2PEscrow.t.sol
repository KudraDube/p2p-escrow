// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {P2PEscrow} from "../src/P2PEscrow.sol";

// ----------------------------------------------------------------------
// Helper contracts used only by the tests
// ----------------------------------------------------------------------

contract MockERC20 is ERC20 {
    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Burns a percentage of every transfer so the receiver gets less than the amount sent.
contract FeeOnTransferToken is ERC20 {
    uint256 public immutable feeBps;

    constructor(uint256 feeBps_) ERC20("Fee Token", "FEE") {
        feeBps = feeBps_;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0) && feeBps > 0) {
            uint256 fee = (value * feeBps) / 10_000;
            super._update(from, address(0), fee); // the fee is burned
            super._update(from, to, value - fee);
        } else {
            super._update(from, to, value);
        }
    }
}

/// @dev A token whose transfer functions call back into the escrow (like a token with hooks).
contract HookToken is ERC20 {
    P2PEscrow public escrow;
    uint256 public mode; // 1: re-enter createOrder during transferFrom. 2: re-enter releaseFunds during transfer.
    bytes public lastError;

    constructor() ERC20("Hook Token", "HOOK") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function configure(P2PEscrow escrow_, uint256 mode_) external {
        escrow = escrow_;
        mode = mode_;
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        if (mode == 1) {
            try escrow.createOrder(address(this), address(0xB0B), 1) {}
            catch (bytes memory err) {
                lastError = err;
            }
        }
        return super.transferFrom(from, to, value);
    }

    function transfer(address to, uint256 value) public override returns (bool) {
        if (mode == 2) {
            try escrow.releaseFunds(0) {}
            catch (bytes memory err) {
                lastError = err;
            }
        }
        return super.transfer(to, value);
    }
}

/// @dev Drives random actions for the invariant test.
contract EscrowHandler is Test {
    P2PEscrow public escrow;
    MockERC20 public token;
    address public arbiter;
    address[] public actors;

    constructor(P2PEscrow escrow_, MockERC20 token_, address arbiter_) {
        escrow = escrow_;
        token = token_;
        arbiter = arbiter_;
        for (uint256 i = 0; i < 4; i++) {
            address actor = makeAddr(string.concat("handlerActor", vm.toString(i)));
            actors.push(actor);
            token.mint(actor, 1_000_000 ether);
            vm.prank(actor);
            token.approve(address(escrow), type(uint256).max);
        }
    }

    function createOrder(uint256 sellerSeed, uint256 buyerSeed, uint256 amount) external {
        address seller = actors[sellerSeed % actors.length];
        address buyer = actors[buyerSeed % actors.length];
        if (seller == buyer) return;
        amount = bound(amount, 1, 1000 ether);
        vm.prank(seller);
        escrow.createOrder(address(token), buyer, amount);
    }

    function markAsPaid(uint256 idSeed) external {
        uint256 count = escrow.nextOrderId();
        if (count == 0) return;
        uint256 id = idSeed % count;
        (, address buyer,,,) = escrow.orders(id);
        vm.prank(buyer);
        try escrow.markAsPaid(id) {} catch {}
    }

    function releaseFunds(uint256 idSeed) external {
        uint256 count = escrow.nextOrderId();
        if (count == 0) return;
        uint256 id = idSeed % count;
        (address seller,,,,) = escrow.orders(id);
        vm.prank(seller);
        try escrow.releaseFunds(id) {} catch {}
    }

    function cancelOrder(uint256 idSeed) external {
        uint256 count = escrow.nextOrderId();
        if (count == 0) return;
        uint256 id = idSeed % count;
        (address seller,,,,) = escrow.orders(id);
        vm.prank(seller);
        try escrow.cancelOrder(id) {} catch {}
    }

    function raiseDispute(uint256 idSeed, bool bySeller) external {
        uint256 count = escrow.nextOrderId();
        if (count == 0) return;
        uint256 id = idSeed % count;
        (address seller, address buyer,,,) = escrow.orders(id);
        vm.prank(bySeller ? seller : buyer);
        try escrow.raiseDispute(id) {} catch {}
    }

    function resolveDispute(uint256 idSeed, bool toBuyer) external {
        uint256 count = escrow.nextOrderId();
        if (count == 0) return;
        uint256 id = idSeed % count;
        vm.prank(arbiter);
        try escrow.resolveDispute(id, toBuyer) {} catch {}
    }

    /// @dev Sum of the amounts of every order that still has tokens locked in the escrow.
    function openAmount() external view returns (uint256 sum) {
        uint256 count = escrow.nextOrderId();
        for (uint256 i = 0; i < count; i++) {
            (,,, uint256 amount, P2PEscrow.OrderStatus status) = escrow.orders(i);
            if (
                status == P2PEscrow.OrderStatus.Funded || status == P2PEscrow.OrderStatus.PaymentClaimed
                    || status == P2PEscrow.OrderStatus.Disputed
            ) {
                sum += amount;
            }
        }
    }
}

// ----------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------

contract P2PEscrowTest is Test {
    P2PEscrow escrow;
    MockERC20 token;
    EscrowHandler handler;

    address arbiter = makeAddr("arbiter");
    address seller = makeAddr("seller");
    address buyer = makeAddr("buyer");
    address stranger = makeAddr("stranger");

    uint256 constant AMOUNT = 100 ether;

    // actions used by the state machine tests
    uint8 constant PAID = 0;
    uint8 constant RELEASE = 1;
    uint8 constant DISPUTE = 2;
    uint8 constant RESOLVE = 3;
    uint8 constant CANCEL = 4;

    event OrderCreated(uint256 indexed orderId, address indexed seller, address indexed buyer, uint256 amount);
    event PaymentClaimed(uint256 indexed orderId);
    event FundsReleased(uint256 indexed orderId);
    event DisputeRaised(uint256 indexed orderId);
    event DisputeResolved(uint256 indexed orderId, bool releasedToBuyer);
    event OrderCancelled(uint256 indexed orderId);

    function setUp() public {
        escrow = new P2PEscrow(arbiter);
        token = new MockERC20("Test Token", "TST");

        token.mint(seller, 1_000_000 ether);
        vm.prank(seller);
        token.approve(address(escrow), type(uint256).max);

        handler = new EscrowHandler(escrow, token, arbiter);
        targetContract(address(handler));
    }

    // ------------------------------------------------------------------
    // helpers
    // ------------------------------------------------------------------

    function _create() internal returns (uint256 id) {
        vm.prank(seller);
        id = escrow.createOrder(address(token), buyer, AMOUNT);
    }

    function _funded() internal returns (uint256 id) {
        id = _create();
    }

    function _claimed() internal returns (uint256 id) {
        id = _create();
        vm.prank(buyer);
        escrow.markAsPaid(id);
    }

    function _released() internal returns (uint256 id) {
        id = _claimed();
        vm.prank(seller);
        escrow.releaseFunds(id);
    }

    function _disputed() internal returns (uint256 id) {
        id = _create();
        vm.prank(seller);
        escrow.raiseDispute(id);
    }

    function _cancelled() internal returns (uint256 id) {
        id = _create();
        vm.prank(seller);
        escrow.cancelOrder(id);
    }

    function _status(uint256 id) internal view returns (P2PEscrow.OrderStatus status) {
        (,,,, status) = escrow.orders(id);
    }

    function _amountOf(uint256 id) internal view returns (uint256 amount) {
        (,,, amount,) = escrow.orders(id);
    }

    // ------------------------------------------------------------------
    // constructor
    // ------------------------------------------------------------------

    function test_constructor_setsArbiterAsOwner() public view {
        assertEq(escrow.owner(), arbiter);
        assertEq(escrow.nextOrderId(), 0);
    }

    function test_constructor_revertsOnZeroArbiter() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new P2PEscrow(address(0));
    }

    // ------------------------------------------------------------------
    // createOrder
    // ------------------------------------------------------------------

    function test_create_locksTokensAndStoresOrder() public {
        uint256 sellerBefore = token.balanceOf(seller);

        uint256 id = _create();

        (address s, address b, address t, uint256 amount, P2PEscrow.OrderStatus status) = escrow.orders(id);
        assertEq(id, 0);
        assertEq(s, seller);
        assertEq(b, buyer);
        assertEq(t, address(token));
        assertEq(amount, AMOUNT);
        assertEq(uint8(status), uint8(P2PEscrow.OrderStatus.Funded));
        assertEq(token.balanceOf(address(escrow)), AMOUNT);
        assertEq(token.balanceOf(seller), sellerBefore - AMOUNT);
    }

    function test_create_emitsEvent() public {
        vm.expectEmit(true, true, true, true);
        emit OrderCreated(0, seller, buyer, AMOUNT);
        _create();
    }

    function test_create_idsIncreaseAndOrdersAreIndependent() public {
        assertEq(_create(), 0);
        vm.prank(seller);
        uint256 second = escrow.createOrder(address(token), stranger, 5 ether);

        assertEq(second, 1);
        assertEq(escrow.nextOrderId(), 2);
        assertEq(_amountOf(0), AMOUNT);
        assertEq(_amountOf(1), 5 ether);
        assertEq(token.balanceOf(address(escrow)), AMOUNT + 5 ether);
    }

    function test_create_revertsOnZeroAmount() public {
        vm.prank(seller);
        vm.expectRevert("amount is zero");
        escrow.createOrder(address(token), buyer, 0);
    }

    function test_create_revertsOnZeroBuyer() public {
        vm.prank(seller);
        vm.expectRevert("invalid buyer");
        escrow.createOrder(address(token), address(0), AMOUNT);
    }

    function test_create_revertsWhenBuyerIsSeller() public {
        vm.prank(seller);
        vm.expectRevert("invalid buyer");
        escrow.createOrder(address(token), seller, AMOUNT);
    }

    function test_create_revertsWithoutAllowance() public {
        vm.prank(stranger);
        vm.expectRevert();
        escrow.createOrder(address(token), buyer, AMOUNT);
    }

    function test_create_revertsWhenSellerHasTooLittle() public {
        token.mint(stranger, 10 ether);
        vm.startPrank(stranger);
        token.approve(address(escrow), type(uint256).max);
        vm.expectRevert();
        escrow.createOrder(address(token), buyer, 11 ether);
        vm.stopPrank();
    }

    function test_create_revertsWhenTokenIsNotAContract() public {
        vm.prank(seller);
        vm.expectRevert();
        escrow.createOrder(address(0xBEEF), buyer, AMOUNT);
    }

    // ------------------------------------------------------------------
    // the patch: fee-on-transfer tokens
    // ------------------------------------------------------------------

    function test_feeOnTransfer_recordsWhatActuallyArrived() public {
        FeeOnTransferToken feeToken = new FeeOnTransferToken(1000); // 10 percent fee
        feeToken.mint(seller, 1000 ether);
        vm.startPrank(seller);
        feeToken.approve(address(escrow), type(uint256).max);
        uint256 id = escrow.createOrder(address(feeToken), buyer, 100 ether);
        vm.stopPrank();

        // The seller sent 100 but only 90 arrived. The order must say 90.
        assertEq(feeToken.balanceOf(address(escrow)), 90 ether);
        (,,, uint256 recorded,) = escrow.orders(id);
        assertEq(recorded, 90 ether);
    }

    function test_feeOnTransfer_eventShowsReceivedAmount() public {
        FeeOnTransferToken feeToken = new FeeOnTransferToken(1000);
        feeToken.mint(seller, 1000 ether);
        vm.startPrank(seller);
        feeToken.approve(address(escrow), type(uint256).max);

        vm.expectEmit(true, true, true, true);
        emit OrderCreated(0, seller, buyer, 90 ether);
        escrow.createOrder(address(feeToken), buyer, 100 ether);
        vm.stopPrank();
    }

    function test_feeOnTransfer_contractStaysSolventForEveryOrder() public {
        FeeOnTransferToken feeToken = new FeeOnTransferToken(1000);
        feeToken.mint(seller, 1000 ether);
        vm.startPrank(seller);
        feeToken.approve(address(escrow), type(uint256).max);
        uint256 first = escrow.createOrder(address(feeToken), buyer, 100 ether);
        uint256 second = escrow.createOrder(address(feeToken), buyer, 100 ether);
        vm.stopPrank();

        // The escrow holds 180 and owes 90 + 90, so both orders can be paid out.
        // If it had recorded 100 + 100 the second release would fail or take other users' funds.
        vm.prank(buyer);
        escrow.markAsPaid(first);
        vm.prank(buyer);
        escrow.markAsPaid(second);
        vm.prank(seller);
        escrow.releaseFunds(first);
        vm.prank(seller);
        escrow.releaseFunds(second);

        assertEq(feeToken.balanceOf(address(escrow)), 0);
    }

    function test_feeOnTransfer_revertsWhenNothingArrives() public {
        FeeOnTransferToken feeToken = new FeeOnTransferToken(10_000); // 100 percent fee
        feeToken.mint(seller, 1000 ether);
        vm.startPrank(seller);
        feeToken.approve(address(escrow), type(uint256).max);
        vm.expectRevert("nothing received");
        escrow.createOrder(address(feeToken), buyer, 100 ether);
        vm.stopPrank();
    }

    function testFuzz_feeOnTransfer_recordedAmountAlwaysMatchesBalance(uint256 amount, uint256 feeBps) public {
        amount = bound(amount, 10_000, 1000 ether);
        feeBps = bound(feeBps, 0, 5000);
        FeeOnTransferToken feeToken = new FeeOnTransferToken(feeBps);
        feeToken.mint(seller, 1000 ether);
        vm.startPrank(seller);
        feeToken.approve(address(escrow), type(uint256).max);
        uint256 id = escrow.createOrder(address(feeToken), buyer, amount);
        vm.stopPrank();

        (,,, uint256 recorded,) = escrow.orders(id);
        assertEq(recorded, feeToken.balanceOf(address(escrow)));
        assertEq(recorded, amount - (amount * feeBps) / 10_000);
    }

    // ------------------------------------------------------------------
    // markAsPaid
    // ------------------------------------------------------------------

    function test_markAsPaid_movesToPaymentClaimedAndEmits() public {
        uint256 id = _funded();

        vm.expectEmit(true, false, false, false);
        emit PaymentClaimed(id);
        vm.prank(buyer);
        escrow.markAsPaid(id);

        assertEq(uint8(_status(id)), uint8(P2PEscrow.OrderStatus.PaymentClaimed));
    }

    function test_markAsPaid_revertsForNonBuyer() public {
        uint256 id = _funded();

        vm.prank(seller);
        vm.expectRevert("not buyer");
        escrow.markAsPaid(id);

        vm.prank(stranger);
        vm.expectRevert("not buyer");
        escrow.markAsPaid(id);
    }

    function test_markAsPaid_revertsOnNonexistentOrder() public {
        vm.prank(buyer);
        vm.expectRevert("not buyer");
        escrow.markAsPaid(999);
    }

    function test_markAsPaid_cannotRunTwice() public {
        uint256 id = _claimed();

        vm.prank(buyer);
        vm.expectRevert("wrong status");
        escrow.markAsPaid(id);
    }

    // ------------------------------------------------------------------
    // releaseFunds
    // ------------------------------------------------------------------

    function test_release_paysBuyerAndClosesOrder() public {
        uint256 id = _claimed();

        vm.expectEmit(true, false, false, false);
        emit FundsReleased(id);
        vm.prank(seller);
        escrow.releaseFunds(id);

        assertEq(token.balanceOf(buyer), AMOUNT);
        assertEq(token.balanceOf(address(escrow)), 0);
        assertEq(uint8(_status(id)), uint8(P2PEscrow.OrderStatus.Released));
    }

    function test_release_revertsForNonSeller() public {
        uint256 id = _claimed();

        vm.prank(buyer);
        vm.expectRevert("not seller");
        escrow.releaseFunds(id);

        vm.prank(stranger);
        vm.expectRevert("not seller");
        escrow.releaseFunds(id);

        vm.prank(arbiter);
        vm.expectRevert("not seller");
        escrow.releaseFunds(id);
    }

    function test_release_revertsBeforePaymentIsClaimed() public {
        uint256 id = _funded();

        vm.prank(seller);
        vm.expectRevert("wrong status");
        escrow.releaseFunds(id);
    }

    function test_release_cannotPayTwice() public {
        uint256 id = _released();

        vm.prank(seller);
        vm.expectRevert("wrong status");
        escrow.releaseFunds(id);
        assertEq(token.balanceOf(buyer), AMOUNT);
    }

    // ------------------------------------------------------------------
    // cancelOrder
    // ------------------------------------------------------------------

    function test_cancel_refundsSellerAndEmits() public {
        uint256 sellerBefore = token.balanceOf(seller);
        uint256 id = _funded();

        vm.expectEmit(true, false, false, false);
        emit OrderCancelled(id);
        vm.prank(seller);
        escrow.cancelOrder(id);

        assertEq(token.balanceOf(seller), sellerBefore);
        assertEq(token.balanceOf(address(escrow)), 0);
        assertEq(uint8(_status(id)), uint8(P2PEscrow.OrderStatus.Cancelled));
    }

    function test_cancel_revertsForNonSeller() public {
        uint256 id = _funded();

        vm.prank(buyer);
        vm.expectRevert("not seller");
        escrow.cancelOrder(id);

        vm.prank(stranger);
        vm.expectRevert("not seller");
        escrow.cancelOrder(id);
    }

    function test_cancel_revertsOnceBuyerClaimedPayment() public {
        uint256 id = _claimed();

        // The seller cannot dodge a buyer who really paid
        vm.prank(seller);
        vm.expectRevert("wrong status");
        escrow.cancelOrder(id);
    }

    function test_cancel_cannotRunTwice() public {
        uint256 id = _cancelled();

        vm.prank(seller);
        vm.expectRevert("wrong status");
        escrow.cancelOrder(id);
    }

    function test_cancel_blocksLaterBuyerClaim() public {
        uint256 id = _cancelled();

        vm.prank(buyer);
        vm.expectRevert("wrong status");
        escrow.markAsPaid(id);
    }

    // ------------------------------------------------------------------
    // raiseDispute
    // ------------------------------------------------------------------

    function test_dispute_sellerCanRaiseWhileFunded() public {
        uint256 id = _funded();

        vm.expectEmit(true, false, false, false);
        emit DisputeRaised(id);
        vm.prank(seller);
        escrow.raiseDispute(id);

        assertEq(uint8(_status(id)), uint8(P2PEscrow.OrderStatus.Disputed));
        assertEq(token.balanceOf(address(escrow)), AMOUNT); // funds stay locked
    }

    function test_dispute_buyerCanRaiseAfterClaiming() public {
        uint256 id = _claimed();

        vm.prank(buyer);
        escrow.raiseDispute(id);

        assertEq(uint8(_status(id)), uint8(P2PEscrow.OrderStatus.Disputed));
    }

    function test_dispute_revertsForStranger() public {
        uint256 id = _funded();

        vm.prank(stranger);
        vm.expectRevert("not a party");
        escrow.raiseDispute(id);

        vm.prank(arbiter);
        vm.expectRevert("not a party");
        escrow.raiseDispute(id);
    }

    function test_dispute_revertsOnClosedOrDisputedOrders() public {
        uint256 released = _released();
        uint256 cancelled = _cancelled();
        uint256 disputed = _disputed();

        vm.startPrank(seller);
        vm.expectRevert("wrong status");
        escrow.raiseDispute(released);
        vm.expectRevert("wrong status");
        escrow.raiseDispute(cancelled);
        vm.expectRevert("wrong status");
        escrow.raiseDispute(disputed);
        vm.stopPrank();
    }

    function test_dispute_blocksNormalFlow() public {
        uint256 id = _disputed();

        vm.prank(buyer);
        vm.expectRevert("wrong status");
        escrow.markAsPaid(id);

        vm.prank(seller);
        vm.expectRevert("wrong status");
        escrow.releaseFunds(id);

        vm.prank(seller);
        vm.expectRevert("wrong status");
        escrow.cancelOrder(id);
    }

    // ------------------------------------------------------------------
    // resolveDispute
    // ------------------------------------------------------------------

    function test_resolve_canPayBuyer() public {
        uint256 id = _disputed();

        vm.expectEmit(true, false, false, true);
        emit DisputeResolved(id, true);
        vm.prank(arbiter);
        escrow.resolveDispute(id, true);

        assertEq(token.balanceOf(buyer), AMOUNT);
        assertEq(token.balanceOf(address(escrow)), 0);
        assertEq(uint8(_status(id)), uint8(P2PEscrow.OrderStatus.Released));
    }

    function test_resolve_canRefundSeller() public {
        uint256 sellerBefore = token.balanceOf(seller);
        uint256 id = _disputed();

        vm.prank(arbiter);
        escrow.resolveDispute(id, false);

        assertEq(token.balanceOf(seller), sellerBefore);
        assertEq(token.balanceOf(buyer), 0);
        assertEq(token.balanceOf(address(escrow)), 0);
    }

    function test_resolve_revertsForEveryoneExceptArbiter() public {
        uint256 id = _disputed();

        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, seller));
        escrow.resolveDispute(id, false);

        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, buyer));
        escrow.resolveDispute(id, true);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        escrow.resolveDispute(id, true);
    }

    function test_resolve_revertsWhenNotDisputed() public {
        uint256 funded = _funded();
        uint256 claimed = _claimed();

        vm.startPrank(arbiter);
        vm.expectRevert("wrong status");
        escrow.resolveDispute(funded, true);
        vm.expectRevert("wrong status");
        escrow.resolveDispute(claimed, true);
        vm.stopPrank();
    }

    function test_resolve_cannotRunTwice() public {
        uint256 id = _disputed();
        vm.prank(arbiter);
        escrow.resolveDispute(id, true);

        vm.prank(arbiter);
        vm.expectRevert("wrong status");
        escrow.resolveDispute(id, false);
        assertEq(token.balanceOf(buyer), AMOUNT); // paid once only
    }

    // ------------------------------------------------------------------
    // the state machine table from the pack, tested exhaustively
    // ------------------------------------------------------------------

    function _bringTo(P2PEscrow.OrderStatus target) internal returns (uint256 id) {
        if (target == P2PEscrow.OrderStatus.None) return 9999; // an order that does not exist
        if (target == P2PEscrow.OrderStatus.Funded) return _funded();
        if (target == P2PEscrow.OrderStatus.PaymentClaimed) return _claimed();
        if (target == P2PEscrow.OrderStatus.Released) return _released();
        if (target == P2PEscrow.OrderStatus.Disputed) return _disputed();
        return _cancelled();
    }

    function _call(uint8 action, uint256 id, address caller) internal returns (bool ok) {
        bytes memory data;
        if (action == PAID) data = abi.encodeCall(P2PEscrow.markAsPaid, (id));
        else if (action == RELEASE) data = abi.encodeCall(P2PEscrow.releaseFunds, (id));
        else if (action == DISPUTE) data = abi.encodeCall(P2PEscrow.raiseDispute, (id));
        else if (action == RESOLVE) data = abi.encodeCall(P2PEscrow.resolveDispute, (id, true));
        else data = abi.encodeCall(P2PEscrow.cancelOrder, (id));

        vm.prank(caller);
        (ok,) = address(escrow).call(data);
    }

    /// @dev The rightful caller for each action.
    function _rightCaller(uint8 action) internal view returns (address) {
        if (action == PAID) return buyer;
        if (action == RESOLVE) return arbiter;
        return seller; // release, dispute and cancel can all be done by the seller
    }

    /// @dev Which statuses allow each action. This is the table from the pack.
    function _allowedIn(uint8 action, uint8 status) internal pure returns (bool) {
        if (action == PAID) return status == 1; // Funded
        if (action == RELEASE) return status == 2; // PaymentClaimed
        if (action == DISPUTE) return status == 1 || status == 2; // Funded or PaymentClaimed
        if (action == RESOLVE) return status == 4; // Disputed
        return status == 1; // cancel: Funded
    }

    function _validStatusFor(uint8 action) internal pure returns (P2PEscrow.OrderStatus) {
        if (action == RELEASE) return P2PEscrow.OrderStatus.PaymentClaimed;
        if (action == RESOLVE) return P2PEscrow.OrderStatus.Disputed;
        return P2PEscrow.OrderStatus.Funded; // paid, dispute and cancel
    }

    function _isAuthorized(uint8 action, address caller) internal view returns (bool) {
        if (action == PAID) return caller == buyer;
        if (action == RELEASE || action == CANCEL) return caller == seller;
        if (action == DISPUTE) return caller == seller || caller == buyer;
        return caller == arbiter; // resolve
    }

    function test_stateMachine_everyActionOnEveryStatus() public {
        for (uint8 status = 0; status <= 5; status++) {
            for (uint8 action = 0; action <= 4; action++) {
                uint256 id = _bringTo(P2PEscrow.OrderStatus(status));
                bool ok = _call(action, id, _rightCaller(action));
                assertEq(
                    ok,
                    _allowedIn(action, status),
                    string.concat("status ", vm.toString(status), " action ", vm.toString(action))
                );
            }
        }
    }

    function test_stateMachine_wrongCallersAlwaysRevert() public {
        address[4] memory callers = [seller, buyer, stranger, arbiter];
        for (uint8 action = 0; action <= 4; action++) {
            for (uint256 c = 0; c < callers.length; c++) {
                if (_isAuthorized(action, callers[c])) continue;
                uint256 id = _bringTo(_validStatusFor(action));
                assertFalse(
                    _call(action, id, callers[c]),
                    string.concat("action ", vm.toString(action), " caller ", vm.toString(c))
                );
            }
        }
    }

    // ------------------------------------------------------------------
    // reentrancy
    // ------------------------------------------------------------------

    function test_reentrancy_tokenCannotReenterCreateOrder() public {
        HookToken hook = new HookToken();
        hook.mint(seller, 1000 ether);
        hook.configure(escrow, 1);
        vm.startPrank(seller);
        hook.approve(address(escrow), type(uint256).max);
        escrow.createOrder(address(hook), buyer, 100 ether);
        vm.stopPrank();

        assertEq(hook.lastError(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
        assertEq(escrow.nextOrderId(), 1); // only the real order exists
    }

    function test_reentrancy_tokenCannotReenterReleaseFunds() public {
        HookToken hook = new HookToken();
        hook.mint(seller, 1000 ether);
        hook.configure(escrow, 0); // honest while the order is set up
        vm.startPrank(seller);
        hook.approve(address(escrow), type(uint256).max);
        uint256 id = escrow.createOrder(address(hook), buyer, 100 ether);
        vm.stopPrank();
        vm.prank(buyer);
        escrow.markAsPaid(id);

        hook.configure(escrow, 2); // now the token tries to re-enter while the escrow pays out
        vm.prank(seller);
        escrow.releaseFunds(id);

        assertEq(hook.lastError(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
        assertEq(hook.balanceOf(buyer), 100 ether); // paid exactly once
        assertEq(hook.balanceOf(address(escrow)), 0);
    }

    // ------------------------------------------------------------------
    // fuzz and invariant tests
    // ------------------------------------------------------------------

    function testFuzz_happyPathPaysBuyerExactly(uint256 amount) public {
        amount = bound(amount, 1, 100_000 ether);

        vm.prank(seller);
        uint256 id = escrow.createOrder(address(token), buyer, amount);
        vm.prank(buyer);
        escrow.markAsPaid(id);
        vm.prank(seller);
        escrow.releaseFunds(id);

        assertEq(token.balanceOf(buyer), amount);
        assertEq(token.balanceOf(address(escrow)), 0);
    }

    function testFuzz_disputeSplitsTheFundsToExactlyOneSide(uint256 amount, bool toBuyer) public {
        amount = bound(amount, 1, 100_000 ether);
        uint256 sellerBefore = token.balanceOf(seller);

        vm.prank(seller);
        uint256 id = escrow.createOrder(address(token), buyer, amount);
        vm.prank(buyer);
        escrow.raiseDispute(id);
        vm.prank(arbiter);
        escrow.resolveDispute(id, toBuyer);

        assertEq(token.balanceOf(address(escrow)), 0);
        if (toBuyer) {
            assertEq(token.balanceOf(buyer), amount);
            assertEq(token.balanceOf(seller), sellerBefore - amount);
        } else {
            assertEq(token.balanceOf(buyer), 0);
            assertEq(token.balanceOf(seller), sellerBefore);
        }
    }

    /// @dev The escrow must hold exactly what its open orders are owed, whatever sequence of actions happens.
    function invariant_escrowBalanceEqualsOpenOrders() public view {
        assertEq(token.balanceOf(address(escrow)), handler.openAmount());
    }
}
