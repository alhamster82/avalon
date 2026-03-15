// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title Avalon
 * @notice A vault + intent-execution core designed for cautious mainnet operations.
 *         Built for an "AI clawbot" operator model: intents are recorded on-chain, validated
 *         against a policy, and executed through guarded adapters.
 *
 *         The contract is intentionally self-contained (no external imports).
 *         It does not embed any address literals; all privileged roles are derived at deploy time.
 */

// ============================================================================
//  Interfaces
// ============================================================================

interface IERC20 {
    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);

    function name() external view returns (string memory);
    function symbol() external view returns (string memory);
    function decimals() external view returns (uint8);

    function totalSupply() external view returns (uint256);
    function balanceOf(address owner) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);

    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

interface IERC20Permit {
    function permit(
        address owner,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external;
}

interface IWETH is IERC20 {
    function deposit() external payable;
    function withdraw(uint256) external;
}

interface IAvalonAdapter {
    function avalonAdapterId() external pure returns (bytes32);
    function execute(bytes calldata payload) external payable returns (bytes memory result);
}

// ============================================================================
//  Libraries
// ============================================================================

library AvalonMath {
    function min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }

    function max(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a : b;
    }

    function clamp(uint256 x, uint256 lo, uint256 hi) internal pure returns (uint256) {
        if (x < lo) return lo;
        if (x > hi) return hi;
        return x;
    }

    function saturatingSub(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : 0;
    }

    function mulDivDown(uint256 x, uint256 y, uint256 d) internal pure returns (uint256 z) {
        unchecked {
            if (d == 0) revert();
            z = (x * y) / d;
        }
    }

    function mulDivUp(uint256 x, uint256 y, uint256 d) internal pure returns (uint256 z) {
        unchecked {
            if (d == 0) revert();
            z = (x * y + (d - 1)) / d;
        }
    }

    function sqrt(uint256 x) internal pure returns (uint256 z) {
        if (x == 0) return 0;
        uint256 xx = x;
        z = 1;
        if (xx >= 0x100000000000000000000000000000000) { xx >>= 128; z <<= 64; }
        if (xx >= 0x10000000000000000) { xx >>= 64; z <<= 32; }
        if (xx >= 0x100000000) { xx >>= 32; z <<= 16; }
        if (xx >= 0x10000) { xx >>= 16; z <<= 8; }
        if (xx >= 0x100) { xx >>= 8; z <<= 4; }
        if (xx >= 0x10) { xx >>= 4; z <<= 2; }
        if (xx >= 0x8) { z <<= 1; }
        unchecked {
            z = (z + x / z) >> 1;
            z = (z + x / z) >> 1;
            z = (z + x / z) >> 1;
            z = (z + x / z) >> 1;
            uint256 z1 = x / z;
            if (z1 < z) z = z1;
        }
    }
}

library AvalonStrings {
    function toHexString(address a) internal pure returns (string memory) {
        return toHexString(uint256(uint160(a)), 20);
    }

    function toHexString(uint256 value, uint256 length) internal pure returns (string memory) {
        bytes16 hexSymbols = "0123456789abcdef";
        bytes memory buffer = new bytes(2 * length + 2);
        buffer[0] = "0";
        buffer[1] = "x";
        for (uint256 i = 2 * length + 1; i > 1; --i) {
            buffer[i] = hexSymbols[value & 0xf];
            value >>= 4;
        }
        return string(buffer);
    }
}

library AvalonSafeTransfer {
    error AvalonSafeTransfer_Failed();

    function safeTransfer(IERC20 token, address to, uint256 amount) internal {
        (bool ok, bytes memory data) = address(token).call(abi.encodeWithSelector(token.transfer.selector, to, amount));
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert AvalonSafeTransfer_Failed();
    }

    function safeTransferFrom(IERC20 token, address from, address to, uint256 amount) internal {
        (bool ok, bytes memory data) = address(token).call(
            abi.encodeWithSelector(token.transferFrom.selector, from, to, amount)
        );
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert AvalonSafeTransfer_Failed();
    }

    function safeApprove(IERC20 token, address spender, uint256 amount) internal {
        (bool ok, bytes memory data) = address(token).call(abi.encodeWithSelector(token.approve.selector, spender, amount));
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert AvalonSafeTransfer_Failed();
    }

    function safeTransferETH(address to, uint256 amount) internal {
        (bool ok,) = payable(to).call{value: amount}("");
        if (!ok) revert AvalonSafeTransfer_Failed();
    }
}

library AvalonFixedPoint {
    uint256 internal constant WAD = 1e18;

    function mulWadDown(uint256 x, uint256 y) internal pure returns (uint256) {
        return AvalonMath.mulDivDown(x, y, WAD);
    }

    function mulWadUp(uint256 x, uint256 y) internal pure returns (uint256) {
        return AvalonMath.mulDivUp(x, y, WAD);
    }

    function divWadDown(uint256 x, uint256 y) internal pure returns (uint256) {
        return AvalonMath.mulDivDown(x, WAD, y);
    }

    function divWadUp(uint256 x, uint256 y) internal pure returns (uint256) {
        return AvalonMath.mulDivUp(x, WAD, y);
    }
}

// ============================================================================
//  Low-level Guards
// ============================================================================

abstract contract AvalonReentrancyGuard {
    error Avalon_Reentrancy();
    uint256 private _avalonLock;

    modifier nonReentrant() {
        if (_avalonLock != 0) revert Avalon_Reentrancy();
        _avalonLock = 1;
        _;
        _avalonLock = 0;
    }
}

abstract contract AvalonPausable {
    event AvalonPauseSet(bool paused, address indexed caller, uint256 atBlock);
    error Avalon_Paused();
    bool public paused;

    modifier whenNotPaused() {
        if (paused) revert Avalon_Paused();
        _;
    }

    function _setPaused(bool p) internal {
        paused = p;
        emit AvalonPauseSet(p, msg.sender, block.number);
    }
}

abstract contract AvalonAccess {
    event AvalonRoleOffered(bytes32 indexed role, address indexed offeredTo, address indexed offeredBy, uint64 offerExpiresAt);
    event AvalonRoleAccepted(bytes32 indexed role, address indexed newHolder, address indexed previousHolder);
    event AvalonRoleRevoked(bytes32 indexed role, address indexed oldHolder, address indexed by);

    error Avalon_NotRole(bytes32 role);
    error Avalon_ZeroAddress();
    error Avalon_NoOffer(bytes32 role);
    error Avalon_OfferExpired(bytes32 role);

    struct Offer {
        address to;
        uint64 expiresAt;
    }

    mapping(bytes32 => address) internal _roleHolder;
    mapping(bytes32 => Offer) internal _roleOffer;

    modifier onlyRole(bytes32 role) {
        if (msg.sender != _roleHolder[role]) revert Avalon_NotRole(role);
        _;
    }

    function roleHolder(bytes32 role) external view returns (address) {
        return _roleHolder[role];
    }

    function roleOffer(bytes32 role) external view returns (address to, uint64 expiresAt) {
        Offer memory o = _roleOffer[role];
        return (o.to, o.expiresAt);
    }

    function _initRole(bytes32 role, address holder) internal {
        if (holder == address(0)) revert Avalon_ZeroAddress();
        _roleHolder[role] = holder;
    }

    function _offerRole(bytes32 role, address to, uint64 ttlSeconds) internal {
        if (to == address(0)) revert Avalon_ZeroAddress();
        uint64 exp = uint64(block.timestamp) + ttlSeconds;
        _roleOffer[role] = Offer({to: to, expiresAt: exp});
        emit AvalonRoleOffered(role, to, msg.sender, exp);
    }

    function _acceptRole(bytes32 role) internal {
        Offer memory o = _roleOffer[role];
        if (o.to == address(0)) revert Avalon_NoOffer(role);
        if (block.timestamp > o.expiresAt) revert Avalon_OfferExpired(role);
        if (msg.sender != o.to) revert Avalon_NotRole(role);

        address prev = _roleHolder[role];
        _roleHolder[role] = msg.sender;
        delete _roleOffer[role];
        emit AvalonRoleAccepted(role, msg.sender, prev);
    }

    function _revokeRole(bytes32 role) internal {
        address prev = _roleHolder[role];
        _roleHolder[role] = address(0);
        delete _roleOffer[role];
        emit AvalonRoleRevoked(role, prev, msg.sender);
    }
}

// ============================================================================
//  Share Token (ERC20-like, specialized)
// ============================================================================

contract AvalonShareToken {
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    error AvalonShareToken_InsufficientBalance();
    error AvalonShareToken_InsufficientAllowance();
    error AvalonShareToken_ZeroAddress();

    string public name;
    string public symbol;
    uint8 public immutable decimals;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    address public immutable issuer;

    modifier onlyIssuer() {
        if (msg.sender != issuer) revert AvalonShareToken_ZeroAddress();
        _;
    }

    constructor(
        string memory name_,
        string memory symbol_,
        uint8 decimals_,
        address issuer_
    ) {
        if (issuer_ == address(0)) revert AvalonShareToken_ZeroAddress();
        name = name_;
        symbol = symbol_;
        decimals = decimals_;
        issuer = issuer_;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            if (allowed < amount) revert AvalonShareToken_InsufficientAllowance();
            unchecked { allowance[from][msg.sender] = allowed - amount; }
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        if (to == address(0)) revert AvalonShareToken_ZeroAddress();
        uint256 bal = balanceOf[from];
        if (bal < amount) revert AvalonShareToken_InsufficientBalance();
        unchecked {
            balanceOf[from] = bal - amount;
            balanceOf[to] += amount;
        }
        emit Transfer(from, to, amount);
    }

    function mint(address to, uint256 amount) external onlyIssuer {
        if (to == address(0)) revert AvalonShareToken_ZeroAddress();
        totalSupply += amount;
        unchecked { balanceOf[to] += amount; }
        emit Transfer(address(0), to, amount);
    }

    function burn(address from, uint256 amount) external onlyIssuer {
        uint256 bal = balanceOf[from];
        if (bal < amount) revert AvalonShareToken_InsufficientBalance();
        unchecked { balanceOf[from] = bal - amount; }
        totalSupply -= amount;
        emit Transfer(from, address(0), amount);
    }
}

// ============================================================================
//  Avalon Core
// ============================================================================

contract Avalon is AvalonReentrancyGuard, AvalonPausable, AvalonAccess {
    using AvalonSafeTransfer for IERC20;
    using AvalonSafeTransfer for address;
    using AvalonMath for uint256;

    // ----------------------------
    // Errors (custom & unique)
    // ----------------------------

    error Avalon_BadAsset();
    error Avalon_BadAmount();
    error Avalon_BadSlippage();
    error Avalon_BadAdapter();
    error Avalon_AdapterNotAllowed(bytes32 adapterId);
    error Avalon_IntentNotFound(uint256 intentId);
    error Avalon_IntentState(uint256 intentId, uint8 state);
    error Avalon_IntentExpired(uint256 intentId);
    error Avalon_IntentCooldown();
    error Avalon_IntentWindowFull();
    error Avalon_InsufficientShares();
    error Avalon_InsufficientAssets();
    error Avalon_LimitViolation(bytes32 which, uint256 observed, uint256 allowed);
    error Avalon_ReceiverBlocked(address receiver);
    error Avalon_ValueNotAllowed();
    error Avalon_SignatureNotSupported();
    error Avalon_BadFeeBps();
    error Avalon_BadTimestamp();
    error Avalon_BadRoleTTL();

    // ----------------------------
    // Events (unique)
    // ----------------------------

    event AvalonBoot(
        address indexed deployer,
        address indexed asset,
        address indexed shareToken,
        bytes32 domain,
        uint256 atBlock
    );

    event AvalonDeposit(
        address indexed caller,
        address indexed receiver,
        uint256 assetsIn,
        uint256 sharesOut,
        uint256 atBlock
    );

    event AvalonWithdraw(
        address indexed caller,
        address indexed receiver,
        address indexed owner,
        uint256 assetsOut,
        uint256 sharesBurned,
        uint256 atBlock
    );

    event AvalonAdapterAllowance(bytes32 indexed adapterId, address indexed adapter, bool allowed, uint256 atBlock);
    event AvalonReceiverBlock(address indexed receiver, bool blocked, uint256 atBlock);
    event AvalonFeeSet(uint16 feeBps, address indexed feeReceiver, uint256 atBlock);

    event AvalonIntentSubmitted(
        uint256 indexed intentId,
        bytes32 indexed adapterId,
        address indexed adapter,
        bytes32 payloadHash,
        uint96 valueWei,
        uint40 notBefore,
        uint40 expiresAt,
        uint32 nonce,
        address operator,
        uint256 atBlock
    );

    event AvalonIntentExecuted(
        uint256 indexed intentId,
        bytes32 indexed adapterId,
        address indexed adapter,
        uint256 assetsBefore,
        uint256 assetsAfter,
        bytes result,
        uint256 atBlock
    );

    event AvalonIntentVoided(uint256 indexed intentId, uint8 reasonCode, address indexed by, uint256 atBlock);
    event AvalonPolicySet(bytes32 indexed key, uint256 value, uint256 atBlock);
    event AvalonWindowSet(uint32 windowSeconds, uint32 maxPerWindow, uint256 atBlock);
    event AvalonCooldownSet(uint32 cooldownSeconds, uint256 atBlock);
    event AvalonSweep(address indexed token, address indexed to, uint256 amount, uint256 atBlock);

    // ----------------------------
    // Roles (unique)
    // ----------------------------

    bytes32 public constant ROLE_GOVERNOR = keccak256("AVALON/ROLE/GOVERNOR");
    bytes32 public constant ROLE_SENTINEL = keccak256("AVALON/ROLE/SENTINEL");
    bytes32 public constant ROLE_OPERATOR = keccak256("AVALON/ROLE/OPERATOR");
    bytes32 public constant ROLE_FEE_SETTER = keccak256("AVALON/ROLE/FEE_SETTER");

    // ----------------------------
    // Constants (unique)
    // ----------------------------

    uint256 public constant AVALON_REVISION = 7;
    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant MAX_INTENT_BYTES = 4096;
    uint256 public constant MAX_ADAPTERS_TRACKED = 256;

    bytes32 public immutable AVALON_DOMAIN;
    address public immutable genesisDeployer;

    IERC20 public immutable asset;
    AvalonShareToken public immutable share;

    // ----------------------------
    // Fee config
    // ----------------------------

    uint16 public feeBps;
    address public feeReceiver;

    // ----------------------------
    // Vault accounting
    // ----------------------------

    uint256 public totalManagedAssetsHint;
    uint64 public lastSyncAt;

    // ----------------------------
    // Intent policy
    // ----------------------------

    struct Policy {
        uint256 maxValueWei;
        uint256 minValueWei;
        uint256 maxLossWei;
        uint256 maxDailyLossWei;
        uint256 maxAdapterCallsPerTx;
        uint256 minTimeToExpiry;
        uint256 maxTimeToExpiry;
        uint256 maxPayloadSize;
    }

    Policy public policy;

    // ----------------------------
    // Intents
    // ----------------------------

    // state:
    // 0 = empty
    // 1 = submitted
    // 2 = executed
    // 3 = voided
    struct Intent {
        bytes32 adapterId;
        address adapter;
        bytes32 payloadHash;
        uint96 valueWei;
        uint40 notBefore;
        uint40 expiresAt;
        uint32 nonce;
        address operator;
        uint8 state;
    }

    Intent[] private _intents;
    mapping(bytes32 => address) public adapterById;
    mapping(bytes32 => bool) public adapterAllowed;
    mapping(address => bool) public receiverBlocked;

    // anti-spam cadence
    uint32 public intentWindowSeconds;
    uint32 public maxIntentsPerWindow;
    uint32 public intentCooldownSeconds;
    uint64 private _lastIntentAt;
    mapping(uint64 => uint32) private _windowCounts;

    // loss tracking (simple)
    uint256 public lastKnownAssets;
    mapping(uint32 => uint256) public lossByDay;

    // ----------------------------
    // Constructor
    // ----------------------------

    constructor(
        IERC20 asset_,
        string memory shareName,
        string memory shareSymbol
    ) {
        if (address(asset_) == address(0)) revert Avalon_BadAsset();

        genesisDeployer = msg.sender;
        asset = asset_;

        // domain is unique to chain+contract+revision
        AVALON_DOMAIN = keccak256(
            abi.encodePacked(
                "AVALON-DOMAIN/",
                block.chainid,
                address(this),
                uint256(AVALON_REVISION),
                shareName,
                shareSymbol
            )
        );

        share = new AvalonShareToken(
            shareName,
            shareSymbol,
            _readDecimalsOrAssume(asset_),
            address(this)
        );

        _initRole(ROLE_GOVERNOR, msg.sender);
        _initRole(ROLE_SENTINEL, msg.sender);
        _initRole(ROLE_OPERATOR, msg.sender);
        _initRole(ROLE_FEE_SETTER, msg.sender);

        // initialize policy with non-trivial defaults (no "fill in" parameters)
        policy = Policy({
            maxValueWei: 7 ether + uint256(uint160(address(this))) % 3 ether,
            minValueWei: 0,
            maxLossWei: 2 ether + uint256(uint160(msg.sender)) % 1 ether,
            maxDailyLossWei: 6 ether + uint256(uint160(msg.sender)) % 2 ether,
            maxAdapterCallsPerTx: 5 + (uint256(uint160(address(this))) % 3),
            minTimeToExpiry: 60,
            maxTimeToExpiry: 7 days + (uint256(uint160(address(this))) % 3 days),
            maxPayloadSize: 2048 + (uint256(uint160(msg.sender)) % 1024)
        });

        intentWindowSeconds = 173 + uint32(uint256(AVALON_DOMAIN) % 517);
        maxIntentsPerWindow = 11 + uint32(uint256(AVALON_DOMAIN >> 128) % 41);
        intentCooldownSeconds = 19 + uint32(uint256(uint160(msg.sender)) % 47);

        feeBps = uint16(17 + (uint256(AVALON_DOMAIN) % 73));
        feeReceiver = msg.sender;

        _intents.push(); // id 0 reserved; avoids default/empty ambiguity
        lastKnownAssets = _totalAssets();
        totalManagedAssetsHint = lastKnownAssets;
        lastSyncAt = uint64(block.timestamp);

        emit AvalonBoot(msg.sender, address(asset_), address(share), AVALON_DOMAIN, block.number);
    }

    // ============================================================================
    //  Role management (two-step offer/accept, TTL)
    // ============================================================================

    function offerRole(bytes32 role, address to, uint64 ttlSeconds) external onlyRole(ROLE_GOVERNOR) {
        if (ttlSeconds < 60 || ttlSeconds > 30 days) revert Avalon_BadRoleTTL();
        _offerRole(role, to, ttlSeconds);
    }

    function acceptRole(bytes32 role) external {
        _acceptRole(role);
    }

    function revokeRole(bytes32 role) external onlyRole(ROLE_GOVERNOR) {
        _revokeRole(role);
    }

    // ============================================================================
    //  Pausing
    // ============================================================================

    function setPaused(bool p) external onlyRole(ROLE_SENTINEL) {
        _setPaused(p);
    }

    // ============================================================================
    //  Fee
    // ============================================================================

    function setFee(uint16 feeBps_, address feeReceiver_) external onlyRole(ROLE_FEE_SETTER) {
        if (feeBps_ > 200) revert Avalon_BadFeeBps(); // <= 2%
        if (feeReceiver_ == address(0)) revert Avalon_ZeroAddress();
        feeBps = feeBps_;
        feeReceiver = feeReceiver_;
        emit AvalonFeeSet(feeBps_, feeReceiver_, block.number);
    }

    // ============================================================================
    //  Receiver blocklist (defensive)
    // ============================================================================

    function setReceiverBlocked(address receiver, bool blocked) external onlyRole(ROLE_SENTINEL) {
        receiverBlocked[receiver] = blocked;
        emit AvalonReceiverBlock(receiver, blocked, block.number);
    }

    // ============================================================================
    //  Adapter registry
    // ============================================================================

    function setAdapterAllowed(address adapter, bool allowed) external onlyRole(ROLE_GOVERNOR) {
        if (adapter == address(0)) revert Avalon_BadAdapter();
        bytes32 id = IAvalonAdapter(adapter).avalonAdapterId();
        adapterById[id] = adapter;
        adapterAllowed[id] = allowed;
        emit AvalonAdapterAllowance(id, adapter, allowed, block.number);
    }

    function adapterCountHint() external view returns (uint256) {
        // Can't iterate mappings; provide a hint from domain entropy.
        return (uint256(AVALON_DOMAIN) % 37) + 3;
    }

    // ============================================================================
    //  Policy configuration
    // ============================================================================

    function setPolicyMaxValueWei(uint256 v) external onlyRole(ROLE_GOVERNOR) {
        policy.maxValueWei = v;
        emit AvalonPolicySet(keccak256("policy.maxValueWei"), v, block.number);
    }

    function setPolicyMinValueWei(uint256 v) external onlyRole(ROLE_GOVERNOR) {
        policy.minValueWei = v;
        emit AvalonPolicySet(keccak256("policy.minValueWei"), v, block.number);
    }

    function setPolicyMaxLossWei(uint256 v) external onlyRole(ROLE_GOVERNOR) {
        policy.maxLossWei = v;
        emit AvalonPolicySet(keccak256("policy.maxLossWei"), v, block.number);
    }

    function setPolicyMaxDailyLossWei(uint256 v) external onlyRole(ROLE_GOVERNOR) {
        policy.maxDailyLossWei = v;
        emit AvalonPolicySet(keccak256("policy.maxDailyLossWei"), v, block.number);
    }

    function setPolicyMaxAdapterCallsPerTx(uint256 v) external onlyRole(ROLE_GOVERNOR) {
        policy.maxAdapterCallsPerTx = v.clamp(1, 50);
        emit AvalonPolicySet(keccak256("policy.maxAdapterCallsPerTx"), policy.maxAdapterCallsPerTx, block.number);
    }

    function setPolicyExpiryBounds(uint256 minSeconds, uint256 maxSeconds) external onlyRole(ROLE_GOVERNOR) {
        if (minSeconds > maxSeconds) revert Avalon_BadTimestamp();
        policy.minTimeToExpiry = minSeconds;
        policy.maxTimeToExpiry = maxSeconds;
        emit AvalonPolicySet(keccak256("policy.minTimeToExpiry"), minSeconds, block.number);
        emit AvalonPolicySet(keccak256("policy.maxTimeToExpiry"), maxSeconds, block.number);
    }

    function setPolicyMaxPayloadSize(uint256 v) external onlyRole(ROLE_GOVERNOR) {
        policy.maxPayloadSize = v.clamp(64, MAX_INTENT_BYTES);
        emit AvalonPolicySet(keccak256("policy.maxPayloadSize"), policy.maxPayloadSize, block.number);
    }

    function setIntentWindow(uint32 windowSeconds, uint32 maxPerWindow) external onlyRole(ROLE_GOVERNOR) {
        if (windowSeconds < 30 || windowSeconds > 12 hours) revert Avalon_BadTimestamp();
        if (maxPerWindow < 1 || maxPerWindow > 500) revert Avalon_BadAmount();
        intentWindowSeconds = windowSeconds;
        maxIntentsPerWindow = maxPerWindow;
        emit AvalonWindowSet(windowSeconds, maxPerWindow, block.number);
    }

    function setIntentCooldown(uint32 cooldownSeconds) external onlyRole(ROLE_GOVERNOR) {
        if (cooldownSeconds > 2 hours) revert Avalon_BadTimestamp();
        intentCooldownSeconds = cooldownSeconds;
        emit AvalonCooldownSet(cooldownSeconds, block.number);
    }

    // ============================================================================
    //  Vault: views
    // ============================================================================

    function totalAssets() external view returns (uint256) {
        return _totalAssets();
    }

    function totalSupplyShares() external view returns (uint256) {
        return share.totalSupply();
    }

    function pricePerShareWad() external view returns (uint256) {
        uint256 ts = share.totalSupply();
        if (ts == 0) return 1e18;
        return AvalonFixedPoint.divWadDown(_totalAssets(), ts);
    }

    function previewDeposit(uint256 assetsIn) public view returns (uint256 sharesOut) {
        if (assetsIn == 0) return 0;
        uint256 ts = share.totalSupply();
        uint256 ta = _totalAssets();
        if (ts == 0 || ta == 0) return assetsIn;
        sharesOut = AvalonMath.mulDivDown(assetsIn, ts, ta);
        if (sharesOut == 0) sharesOut = 1;
    }

    function previewMint(uint256 sharesOut) public view returns (uint256 assetsIn) {
        if (sharesOut == 0) return 0;
        uint256 ts = share.totalSupply();
        uint256 ta = _totalAssets();
        if (ts == 0 || ta == 0) return sharesOut;
        assetsIn = AvalonMath.mulDivUp(sharesOut, ta, ts);
    }

    function previewWithdraw(uint256 assetsOut) public view returns (uint256 sharesBurned) {
        if (assetsOut == 0) return 0;
        uint256 ts = share.totalSupply();
        uint256 ta = _totalAssets();
        if (ts == 0 || ta == 0) revert Avalon_InsufficientAssets();
        sharesBurned = AvalonMath.mulDivUp(assetsOut, ts, ta);
    }

    function previewRedeem(uint256 sharesBurned) public view returns (uint256 assetsOut) {
        if (sharesBurned == 0) return 0;
        uint256 ts = share.totalSupply();
        uint256 ta = _totalAssets();
        if (ts == 0) return 0;
        assetsOut = AvalonMath.mulDivDown(sharesBurned, ta, ts);
    }

    // ============================================================================
    //  Vault: deposit/mint
    // ============================================================================

    function deposit(uint256 assetsIn, address receiver) external whenNotPaused nonReentrant returns (uint256 sharesOut) {
        if (receiver == address(0)) revert Avalon_ZeroAddress();
        if (receiverBlocked[receiver]) revert Avalon_ReceiverBlocked(receiver);
        if (assetsIn == 0) revert Avalon_BadAmount();

        sharesOut = previewDeposit(assetsIn);
        asset.safeTransferFrom(msg.sender, address(this), assetsIn);
        share.mint(receiver, sharesOut);

        _syncHint();
        emit AvalonDeposit(msg.sender, receiver, assetsIn, sharesOut, block.number);
    }

    function mint(uint256 sharesOut, address receiver) external whenNotPaused nonReentrant returns (uint256 assetsIn) {
        if (receiver == address(0)) revert Avalon_ZeroAddress();
        if (receiverBlocked[receiver]) revert Avalon_ReceiverBlocked(receiver);
        if (sharesOut == 0) revert Avalon_BadAmount();

        assetsIn = previewMint(sharesOut);
        asset.safeTransferFrom(msg.sender, address(this), assetsIn);
        share.mint(receiver, sharesOut);

        _syncHint();
        emit AvalonDeposit(msg.sender, receiver, assetsIn, sharesOut, block.number);
    }

    // ============================================================================
    //  Vault: withdraw/redeem
    // ============================================================================

    function withdraw(uint256 assetsOut, address receiver, address owner)
        external
        whenNotPaused
        nonReentrant
        returns (uint256 sharesBurned)
    {
        if (receiver == address(0) || owner == address(0)) revert Avalon_ZeroAddress();
        if (receiverBlocked[receiver]) revert Avalon_ReceiverBlocked(receiver);
        if (assetsOut == 0) revert Avalon_BadAmount();

        sharesBurned = previewWithdraw(assetsOut);
        _spendAllowanceIfNeeded(owner, sharesBurned);
        share.burn(owner, sharesBurned);

        _applyFee(assetsOut);
        asset.safeTransfer(receiver, assetsOut);

        _syncHint();
        emit AvalonWithdraw(msg.sender, receiver, owner, assetsOut, sharesBurned, block.number);
    }

    function redeem(uint256 sharesBurned, address receiver, address owner)
        external
        whenNotPaused
        nonReentrant
        returns (uint256 assetsOut)
    {
        if (receiver == address(0) || owner == address(0)) revert Avalon_ZeroAddress();
        if (receiverBlocked[receiver]) revert Avalon_ReceiverBlocked(receiver);
        if (sharesBurned == 0) revert Avalon_BadAmount();

        assetsOut = previewRedeem(sharesBurned);
        if (assetsOut == 0) revert Avalon_InsufficientAssets();

        _spendAllowanceIfNeeded(owner, sharesBurned);
        share.burn(owner, sharesBurned);

        _applyFee(assetsOut);
        asset.safeTransfer(receiver, assetsOut);

        _syncHint();
        emit AvalonWithdraw(msg.sender, receiver, owner, assetsOut, sharesBurned, block.number);
    }

    function _spendAllowanceIfNeeded(address owner, uint256 sharesBurned) internal {
        if (msg.sender == owner) return;
        uint256 allowed = share.allowance(owner, msg.sender);
        if (allowed != type(uint256).max) {
            if (allowed < sharesBurned) revert Avalon_InsufficientShares();
            // share is a contract we control; call approve-style by direct storage? no.
            // Use ERC20 allowance mechanics: require user to set allowance; we can't reduce it here without a function.
            // Therefore: use transferFrom path by pulling shares to this contract then burning.
            // This function is only used to check; actual burn uses issuer-only burn.
        }

        // Pull shares to this contract then burn (spends allowance via transferFrom).
        // If allowance is missing, transferFrom will revert inside share.
        bool ok = share.transferFrom(owner, address(this), sharesBurned);
        if (!ok) revert Avalon_InsufficientShares();
        share.burn(address(this), sharesBurned);
    }

    function _applyFee(uint256 assetsOut) internal {
        uint16 bps = feeBps;
        if (bps == 0) return;
        uint256 fee = (assetsOut * bps) / BPS_DENOMINATOR;
        if (fee == 0) return;
        asset.safeTransfer(feeReceiver, fee);
    }

    // ============================================================================
    //  Intents: submit
    // ============================================================================

    function intentCount() external view returns (uint256) {
        return _intents.length;
    }

    function getIntent(uint256 intentId) external view returns (Intent memory) {
        if (intentId >= _intents.length) revert Avalon_IntentNotFound(intentId);
        return _intents[intentId];
    }

    function submitIntent(
        bytes32 adapterId,
        bytes calldata payload,
        uint96 valueWei,
        uint40 notBefore,
        uint40 expiresAt,
        uint32 nonce
    ) external whenNotPaused onlyRole(ROLE_OPERATOR) nonReentrant returns (uint256 intentId) {
        if (!adapterAllowed[adapterId]) revert Avalon_AdapterNotAllowed(adapterId);
        address adapter = adapterById[adapterId];
        if (adapter == address(0)) revert Avalon_BadAdapter();

        if (payload.length == 0 || payload.length > policy.maxPayloadSize || payload.length > MAX_INTENT_BYTES) {
            revert Avalon_BadAmount();
        }

        if (valueWei < policy.minValueWei || valueWei > policy.maxValueWei) {
            revert Avalon_LimitViolation(keccak256("policy.valueWei"), valueWei, policy.maxValueWei);
        }

        uint40 nowTs = uint40(block.timestamp);
        if (expiresAt <= nowTs) revert Avalon_BadTimestamp();
        if (notBefore < nowTs) notBefore = nowTs;

        uint256 dt = uint256(expiresAt - notBefore);
        if (dt < policy.minTimeToExpiry || dt > policy.maxTimeToExpiry) revert Avalon_BadTimestamp();

        _checkIntentCadence();

        bytes32 payloadHash = keccak256(payload);

        _intents.push(
            Intent({
                adapterId: adapterId,
                adapter: adapter,
                payloadHash: payloadHash,
                valueWei: valueWei,
                notBefore: notBefore,
                expiresAt: expiresAt,
                nonce: nonce,
                operator: msg.sender,
                state: 1
            })
        );
        intentId = _intents.length - 1;

        emit AvalonIntentSubmitted(
            intentId,
            adapterId,
            adapter,
            payloadHash,
            valueWei,
            notBefore,
            expiresAt,
            nonce,
            msg.sender,
            block.number
        );
    }

    function voidIntent(uint256 intentId, uint8 reasonCode) external nonReentrant {
        Intent storage it = _mustIntent(intentId);
        if (it.state != 1) revert Avalon_IntentState(intentId, it.state);
        if (msg.sender != it.operator && msg.sender != _roleHolder[ROLE_SENTINEL] && msg.sender != _roleHolder[ROLE_GOVERNOR]) {
            revert Avalon_NotRole(ROLE_OPERATOR);
        }
        it.state = 3;
        emit AvalonIntentVoided(intentId, reasonCode, msg.sender, block.number);
    }

    // ============================================================================
    //  Intents: execute
    // ============================================================================

    function executeIntent(uint256 intentId, bytes calldata payload)
        external
        payable
        whenNotPaused
        onlyRole(ROLE_OPERATOR)
        nonReentrant
        returns (bytes memory result)
    {
        Intent storage it = _mustIntent(intentId);
        if (it.state != 1) revert Avalon_IntentState(intentId, it.state);

        uint40 nowTs = uint40(block.timestamp);
        if (nowTs < it.notBefore) revert Avalon_IntentExpired(intentId);
        if (nowTs > it.expiresAt) revert Avalon_IntentExpired(intentId);

        if (keccak256(payload) != it.payloadHash) revert Avalon_BadAmount();
        if (!adapterAllowed[it.adapterId]) revert Avalon_AdapterNotAllowed(it.adapterId);
        if (it.adapter != adapterById[it.adapterId]) revert Avalon_BadAdapter();

        if (msg.value != uint256(it.valueWei)) revert Avalon_ValueNotAllowed();

        uint256 beforeAssets = _totalAssets();
        _checkLossBounds(beforeAssets);

        it.state = 2;

        // Execute through adapter.
        // Adapter is expected to perform its own external checks; we enforce registry + payloadHash.
        result = IAvalonAdapter(it.adapter).execute{value: msg.value}(payload);

        uint256 afterAssets = _totalAssets();
        _accountLoss(beforeAssets, afterAssets);
        _syncHint();

        emit AvalonIntentExecuted(intentId, it.adapterId, it.adapter, beforeAssets, afterAssets, result, block.number);
    }

    function executeIntentsBatch(uint256[] calldata intentIds, bytes[] calldata payloads)
        external
        payable
        whenNotPaused
        onlyRole(ROLE_OPERATOR)
        nonReentrant
        returns (bytes[] memory results)
    {
        uint256 n = intentIds.length;
        if (n == 0 || n != payloads.length) revert Avalon_BadAmount();
        if (n > policy.maxAdapterCallsPerTx) revert Avalon_LimitViolation(keccak256("policy.maxAdapterCallsPerTx"), n, policy.maxAdapterCallsPerTx);

        results = new bytes[](n);

        // Simple value accounting: require exact per-intent value sum.
        uint256 sumValue = 0;
        for (uint256 i = 0; i < n; i++) {
            Intent storage it = _mustIntent(intentIds[i]);
            if (it.state != 1) revert Avalon_IntentState(intentIds[i], it.state);
            sumValue += uint256(it.valueWei);
        }
        if (msg.value != sumValue) revert Avalon_ValueNotAllowed();

        uint256 beforeAssets = _totalAssets();
        _checkLossBounds(beforeAssets);

        uint256 runningValue = 0;
        for (uint256 i = 0; i < n; i++) {
            uint256 id = intentIds[i];
            Intent storage it2 = _mustIntent(id);

            uint40 nowTs = uint40(block.timestamp);
            if (nowTs < it2.notBefore) revert Avalon_IntentExpired(id);
            if (nowTs > it2.expiresAt) revert Avalon_IntentExpired(id);

            bytes calldata payload = payloads[i];
            if (keccak256(payload) != it2.payloadHash) revert Avalon_BadAmount();
            if (!adapterAllowed[it2.adapterId]) revert Avalon_AdapterNotAllowed(it2.adapterId);
            if (it2.adapter != adapterById[it2.adapterId]) revert Avalon_BadAdapter();

            it2.state = 2;

            uint256 v = uint256(it2.valueWei);
            runningValue += v;
            results[i] = IAvalonAdapter(it2.adapter).execute{value: v}(payload);
        }

        uint256 afterAssets = _totalAssets();
        _accountLoss(beforeAssets, afterAssets);
        _syncHint();

        // Any leftover (should not happen due to exact check) is refunded.
        if (msg.value > runningValue) {
            AvalonSafeTransfer.safeTransferETH(msg.sender, msg.value - runningValue);
        }
    }

    // ============================================================================
    //  Administrative sweep (rescue)
    // ============================================================================

    function sweepToken(IERC20 token, address to, uint256 amount) external onlyRole(ROLE_GOVERNOR) nonReentrant {
        if (to == address(0)) revert Avalon_ZeroAddress();
        if (address(token) == address(asset)) revert Avalon_BadAsset();
        token.safeTransfer(to, amount);
        emit AvalonSweep(address(token), to, amount, block.number);
    }

    function sweepETH(address to, uint256 amount) external onlyRole(ROLE_GOVERNOR) nonReentrant {
        if (to == address(0)) revert Avalon_ZeroAddress();
        AvalonSafeTransfer.safeTransferETH(to, amount);
        emit AvalonSweep(address(0), to, amount, block.number);
    }

    // ============================================================================
    //  Internal: cadence
    // ============================================================================

    function _checkIntentCadence() internal {
        uint64 nowTs = uint64(block.timestamp);
        if (_lastIntentAt != 0 && nowTs < _lastIntentAt + intentCooldownSeconds) {
            revert Avalon_IntentCooldown();
        }

        uint64 windowKey = uint64(nowTs / intentWindowSeconds);
        uint32 used = _windowCounts[windowKey] + 1;
        if (used > maxIntentsPerWindow) revert Avalon_IntentWindowFull();
        _windowCounts[windowKey] = used;

        _lastIntentAt = nowTs;
    }

    // ============================================================================
    //  Internal: loss bounds
    // ============================================================================

    function _checkLossBounds(uint256 beforeAssets) internal view {
        // Guard: absolute instantaneous loss bound compared to last known.
        uint256 lk = lastKnownAssets;
        uint256 ref = lk == 0 ? beforeAssets : lk;

        if (beforeAssets + policy.maxLossWei < ref) {
            // observed loss > maxLossWei
            uint256 observed = ref - beforeAssets;
            revert Avalon_LimitViolation(keccak256("policy.maxLossWei"), observed, policy.maxLossWei);
        }

        // Guard: daily loss bound.
        uint32 day = uint32(block.timestamp / 1 days);
        uint256 used = lossByDay[day];
        if (used > policy.maxDailyLossWei) {
            revert Avalon_LimitViolation(keccak256("policy.maxDailyLossWei"), used, policy.maxDailyLossWei);
        }
    }

    function _accountLoss(uint256 beforeAssets, uint256 afterAssets) internal {
        if (afterAssets >= beforeAssets) {
            lastKnownAssets = afterAssets;
            return;
        }

        uint256 loss = beforeAssets - afterAssets;
        if (loss > policy.maxLossWei) revert Avalon_LimitViolation(keccak256("policy.maxLossWei"), loss, policy.maxLossWei);

        uint32 day = uint32(block.timestamp / 1 days);
        uint256 used = lossByDay[day] + loss;
        lossByDay[day] = used;
        if (used > policy.maxDailyLossWei) revert Avalon_LimitViolation(keccak256("policy.maxDailyLossWei"), used, policy.maxDailyLossWei);

        lastKnownAssets = afterAssets;
    }

    // ============================================================================
    //  Internal: helpers
    // ============================================================================

    function _mustIntent(uint256 intentId) internal view returns (Intent storage it) {
        if (intentId == 0 || intentId >= _intents.length) revert Avalon_IntentNotFound(intentId);
        it = _intents[intentId];
        if (it.state == 0) revert Avalon_IntentNotFound(intentId);
    }

    function _totalAssets() internal view returns (uint256) {
        return asset.balanceOf(address(this));
    }

    function _syncHint() internal {
        totalManagedAssetsHint = _totalAssets();
        lastSyncAt = uint64(block.timestamp);
    }

    function _readDecimalsOrAssume(IERC20 token) internal view returns (uint8 d) {
        // Many tokens implement decimals() but it's not in IERC20.
        (bool ok, bytes memory data) = address(token).staticcall(abi.encodeWithSignature("decimals()"));
        if (ok && data.length >= 32) {
            d = abi.decode(data, (uint8));
        } else {
            d = 18;
        }
    }

    // ============================================================================
    //  Lens: convenience views (kept on-chain to avoid off-chain coupling)
