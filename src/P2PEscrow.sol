// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ===== BORROWED FROM OPENZEPPELIN =====
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract P2PEscrow is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;
    // ========================================

    // ===== CUSTOM LOGIC =====

    // The state machine. An order can only move forward through these
    // stages in order, never backward, except via dispute resolution
    // or cancellation before payment is claimed.
    enum OrderStatus {
        None,     
        Funded,     
        PaymentClaimed, 
        Released,
        Disputed,  
        Cancelled  
    }

    struct Order {
        address seller;
        address buyer;
        address token;
        uint256 amount;
        OrderStatus status;
    }

    uint256 public nextOrderId;
    mapping(uint256 => Order) public orders;

    event OrderCreated(uint256 indexed orderId, address indexed seller, address indexed buyer, uint256 amount);
    event PaymentClaimed(uint256 indexed orderId);
    event FundsReleased(uint256 indexed orderId);
    event DisputeRaised(uint256 indexed orderId);
    event DisputeResolved(uint256 indexed orderId, bool releasedToBuyer);
    event OrderCancelled(uint256 indexed orderId);

    constructor(address initialArbiter) Ownable(initialArbiter) {}

    // Seller locks funds into escrow and names the buyer up front.
    // Naming the buyer prevents anyone else from claiming payment on
    // this order later.
    function createOrder(address token, address buyer, uint256 amount) external nonReentrant returns (uint256 orderId) {
        require(amount > 0, "amount is zero");
        require(buyer != address(0) && buyer != msg.sender, "invalid buyer");

        orderId = nextOrderId++;
        orders[orderId] = Order({
            seller: msg.sender,
            buyer: buyer,
            token: token,
            amount: amount,
            status: OrderStatus.Funded
        });

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        emit OrderCreated(orderId, msg.sender, buyer, amount);
    }

    // Buyer marks that they've sent the fiat off-chain. This is purely
    // informational on-chain, the actual payment happens outside the
    // contract, but it moves the order into a state where the seller
    // is expected to check their bank account and release.
    function markAsPaid(uint256 orderId) external {
        Order storage order = orders[orderId];
        require(msg.sender == order.buyer, "not buyer");
        require(order.status == OrderStatus.Funded, "wrong status");

        order.status = OrderStatus.PaymentClaimed;
        emit PaymentClaimed(orderId);
    }

    // Seller confirms fiat arrived and releases the escrowed tokens.
    function releaseFunds(uint256 orderId) external nonReentrant {
        Order storage order = orders[orderId];
        require(msg.sender == order.seller, "not seller");
        require(order.status == OrderStatus.PaymentClaimed, "wrong status");

        order.status = OrderStatus.Released;
        IERC20(order.token).safeTransfer(order.buyer, order.amount);
        emit FundsReleased(orderId);
    }

    // Either party can escalate if something's gone wrong, funds stay
    // locked in the contract until the arbiter resolves it.
    function raiseDispute(uint256 orderId) external {
        Order storage order = orders[orderId];
        require(msg.sender == order.seller || msg.sender == order.buyer, "not a party");
        require(order.status == OrderStatus.Funded || order.status == OrderStatus.PaymentClaimed, "wrong status");

        order.status = OrderStatus.Disputed;
        emit DisputeRaised(orderId);
    }

    // Arbiter decides. This is the safety valve that stops funds from
    // ever being permanently stuck if buyer and seller disagree.
    function resolveDispute(uint256 orderId, bool releaseToBuyer) external onlyOwner nonReentrant {
        Order storage order = orders[orderId];
        require(order.status == OrderStatus.Disputed, "wrong status");

        order.status = OrderStatus.Released;
        address recipient = releaseToBuyer ? order.buyer : order.seller;
        IERC20(order.token).safeTransfer(recipient, order.amount);
        emit DisputeResolved(orderId, releaseToBuyer);
    }

    // Seller can pull out only before the buyer has claimed payment.
    // Once markAsPaid has been called, cancelling would let a seller
    // dodge a buyer who genuinely already sent the fiat.
    function cancelOrder(uint256 orderId) external nonReentrant {
        Order storage order = orders[orderId];
        require(msg.sender == order.seller, "not seller");
        require(order.status == OrderStatus.Funded, "wrong status");

        order.status = OrderStatus.Cancelled;
        IERC20(order.token).safeTransfer(order.seller, order.amount);
        emit OrderCancelled(orderId);
    }
    // ========================================
}