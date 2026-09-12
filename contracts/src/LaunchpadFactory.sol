// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {
    Types, IFeeEscrow, IHolderFeeSharing, IBondingCurve, IMemeHook, IGraduationExecutor, ILaunchDeployer
} from "./interfaces/ILaunchpad.sol";

/// @notice Entry point for launches and graduation. Owner-managed policy (fees, launch templates, approved quote
///         assets, whitelist), CREATE2 deployment of each token and curve, the launch registry, graduation into the
///         Uniswap v4 pool, the stuck-launch valve, and timelocked community takeovers of a creator's fee stream.
contract LaunchpadFactory {
    uint256 public constant MAX_EXEMPTIONS = 32;
    uint256 public constant TAKEOVER_DELAY = 3 days;
    uint256 public constant TAKEOVER_WINDOW = 3 days;
    uint256 public constant RESCUE_DELAY = 7 days;
    /// @dev Gas reserved for the automatic graduation. Without a floor, gas estimation settles on a limit where the
    ///      completing buy succeeds while the caught inner call runs out of gas, leaving every launch "stuck".
    uint256 public constant GRADUATION_GAS = 2_000_000;
    address private constant DEAD = 0x000000000000000000000000000000000000dEaD;

    IPoolManager public immutable poolManager;

    address public owner;
    address public pendingOwner;

    address public hook;
    address public graduationExecutor; // Uniswap v4 graduation venue
    address public mondayExecutor; // Monday Trade graduation venue (creator-selectable; the only venue for aBIL)
    address public locker;
    address public escrow;
    address public holderFeeSharing;
    address public router;
    address public launchDeployer;

    uint256 public launchFee; // native, paid on every launch
    address public protocolFeeRecipient;
    uint16 public protocolFeeShareBps;
    uint16 public maxCreatorTaxBps;
    bool public whitelistEnabled;
    mapping(address => bool) public whitelisted;

    Types.LaunchConfig[] private _configs;
    mapping(address => Types.PairEconomics) public pairTokenEconomics;
    /// @dev Pair assets that may ONLY graduate on Monday Trade (e.g. the RWA quote asset aBIL). A launch quoted in
    ///      such an asset must choose the Monday venue; a Uniswap v4 choice is rejected at launch.
    mapping(address => bool) public pairMondayOnly;

    mapping(address => Types.LaunchedToken) private _launches;
    address[] private _allTokens;
    mapping(address => address) public curveToToken;
    mapping(address => uint256) public stuckSince;

    struct Proposal {
        address newRecipient;
        uint256 effectiveAt;
        uint256 expiresAt;
    }

    mapping(address => Proposal) public pendingCreatorFeeRecipient;

    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event ModulesSet(address hook, address executor, address locker, address escrow, address sharing, address router, address deployer);
    event MondayExecutorSet(address executor);
    event PairMondayOnlySet(address indexed pairToken, bool mondayOnly);
    event LaunchFeeSet(uint256 fee);
    event FeePolicySet(address recipient, uint16 protocolShareBps);
    event MaxCreatorTaxSet(uint16 bps);
    event WhitelistSet(bool enabled);
    event WhitelistedSet(address indexed account, bool allowed);
    event LaunchConfigAdded(uint256 indexed id);
    event LaunchConfigEnabled(uint256 indexed id, bool enabled);
    event PairEconomicsSet(address indexed pairToken, uint256 phantomQuote, uint256 graduationThreshold, uint8 decimals, bool approved);
    event TokenLaunched(address indexed token, address indexed curve, address indexed deployer, address pairToken, uint256 launchConfigId, uint256 graduationThreshold);
    event LaunchSwept(address indexed token);
    event PoolGraduated(address indexed token, bytes32 indexed poolId, uint128 liquidity);
    event AutoGraduationFailed(address indexed token);
    event LaunchRescued(address indexed token);
    event CreatorFeeRecipientChangeProposed(address indexed token, address newRecipient, uint256 effectiveAt, uint256 expiresAt);
    event CreatorFeeRecipientChangeCancelled(address indexed token);
    event CreatorFeeRecipientUpdated(address indexed token, address newRecipient);

    error NotOwner();
    error InsufficientGasForGraduation();
    error NotPendingOwner();
    error NotRouter();
    error NotCurve();
    error NotCreatorFeeRecipient();
    error ModulesLocked();
    error ModulesNotSet();
    error InvalidBps();
    error NotWhitelisted();
    error LaunchConfigDisabled();
    error PairTokenNotApproved();
    error PairTokenDecimalsMismatch();
    error PairRequiresMonday();
    error GraduationVenueUnavailable();
    error LaunchFeeNotPaid();
    error CreatorTaxTooHigh();
    error ExemptionListTooLong();
    error LaunchEconomicsMismatch();
    error UnknownLaunch();
    error WrongGraduationPhase();
    error NotStuck();
    error TimelockNotElapsed();
    error TimelockExpired();
    error NoProposal();
    error Create2Mismatch();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(IPoolManager _poolManager, address _protocolFeeRecipient, uint256 _launchFee, uint16 _protocolFeeShareBps, uint16 _maxCreatorTaxBps) {
        if (_protocolFeeShareBps > 10_000 || _maxCreatorTaxBps > 10_000) revert InvalidBps();
        poolManager = _poolManager;
        owner = msg.sender;
        protocolFeeRecipient = _protocolFeeRecipient;
        launchFee = _launchFee;
        protocolFeeShareBps = _protocolFeeShareBps;
        maxCreatorTaxBps = _maxCreatorTaxBps;
        emit OwnershipTransferred(address(0), msg.sender);
    }

    // ------------------------------------------------------------------ ownership

    function transferOwnership(address newOwner) external onlyOwner {
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        emit OwnershipTransferred(owner, msg.sender);
        owner = msg.sender;
        pendingOwner = address(0);
    }

    // ------------------------------------------------------------------ admin

    /// @notice Wires the modules. The hook, locker, escrow and sharing contracts are fixed once the first launch
    ///         exists; the executor and router can be replaced (e.g. a new graduation venue).
    function setModules(address _hook, address _executor, address _locker, address _escrow, address _sharing, address _router, address _deployer)
        external
        onlyOwner
    {
        if (_allTokens.length != 0 && (_hook != hook || _locker != locker || _escrow != escrow || _sharing != holderFeeSharing)) revert ModulesLocked();
        hook = _hook;
        graduationExecutor = _executor;
        locker = _locker;
        escrow = _escrow;
        holderFeeSharing = _sharing;
        router = _router;
        launchDeployer = _deployer;
        IHolderFeeSharing(_sharing).setAuthorized(_hook, true);
        emit ModulesSet(_hook, _executor, _locker, _escrow, _sharing, _router, _deployer);
    }

    /// @notice Sets the Monday Trade graduation executor. Like the Uniswap v4 executor it can be replaced (e.g. a new
    ///         venue version). Launches that chose Monday, and any aBIL/Monday-only pair, need this set.
    function setMondayExecutor(address _mondayExecutor) external onlyOwner {
        mondayExecutor = _mondayExecutor;
        emit MondayExecutorSet(_mondayExecutor);
    }

    function setLaunchFee(uint256 fee) external onlyOwner {
        launchFee = fee;
        emit LaunchFeeSet(fee);
    }

    function setFeePolicy(address recipient, uint16 protocolShareBps) external onlyOwner {
        if (protocolShareBps > 10_000) revert InvalidBps();
        protocolFeeRecipient = recipient;
        protocolFeeShareBps = protocolShareBps;
        emit FeePolicySet(recipient, protocolShareBps);
    }

    function setMaxCreatorTaxBps(uint16 bps) external onlyOwner {
        if (bps > 10_000) revert InvalidBps();
        maxCreatorTaxBps = bps;
        emit MaxCreatorTaxSet(bps);
    }

    function setWhitelistEnabled(bool enabled) external onlyOwner {
        whitelistEnabled = enabled;
        emit WhitelistSet(enabled);
    }

    function setWhitelisted(address[] calldata accounts, bool allowed) external onlyOwner {
        for (uint256 i = 0; i < accounts.length; i++) {
            whitelisted[accounts[i]] = allowed;
            emit WhitelistedSet(accounts[i], allowed);
        }
    }

    function addLaunchConfig(Types.LaunchConfig calldata config) external onlyOwner returns (uint256 id) {
        if (config.curveFeeBps > 10_000 || config.poolFeeBps > 10_000) revert InvalidBps();
        for (uint256 i = 0; i < config.snipeTaxSchedule.length; i++) {
            if (config.snipeTaxSchedule[i] > 10_000) revert InvalidBps();
        }
        _configs.push(config);
        id = _configs.length - 1;
        emit LaunchConfigAdded(id);
    }

    function setLaunchConfigEnabled(uint256 id, bool enabled) external onlyOwner {
        _configs[id].enabled = enabled;
        emit LaunchConfigEnabled(id, enabled);
    }

    function setPairEconomics(address pairToken, uint256 phantomQuote, uint256 graduationThreshold, uint8 decimals, bool approved) external onlyOwner {
        pairTokenEconomics[pairToken] = Types.PairEconomics(phantomQuote, graduationThreshold, decimals, approved);
        emit PairEconomicsSet(pairToken, phantomQuote, graduationThreshold, decimals, approved);
    }

    /// @notice Marks a quote asset as Monday-only (used for the RWA quote asset aBIL). Launches quoted in it must
    ///         graduate on Monday Trade; choosing Uniswap v4 reverts with `PairRequiresMonday`.
    function setPairMondayOnly(address pairToken, bool mondayOnly) external onlyOwner {
        pairMondayOnly[pairToken] = mondayOnly;
        emit PairMondayOnlySet(pairToken, mondayOnly);
    }

    // ------------------------------------------------------------------ launching

    function previewLaunchEconomics(uint256 launchConfigId, address pairToken) public view returns (bytes32) {
        Types.LaunchConfig storage cfg = _configs[launchConfigId];
        Types.PairEconomics storage econ = pairTokenEconomics[pairToken];
        return keccak256(
            abi.encode(
                launchConfigId, cfg.supply, cfg.curveFeeBps, cfg.poolFeeBps, cfg.tickSpacing, cfg.snipeTaxSchedule,
                pairToken, econ.phantomQuote, econ.graduationThreshold, econ.decimals,
                launchFee, protocolFeeShareBps, maxCreatorTaxBps
            )
        );
    }

    function launchToken(Types.TokenParams calldata params, uint256 launchConfigId, address pairToken, address[] calldata snipeTaxExemptions)
        external
        payable
        returns (address token, address curve)
    {
        return _launch(params, launchConfigId, pairToken, snipeTaxExemptions, msg.sender);
    }

    /// @notice Launch on behalf of `deployer`; only the launch-and-buy router may call this.
    function launchTokenFor(Types.TokenParams calldata params, uint256 launchConfigId, address pairToken, address[] calldata snipeTaxExemptions, address deployer)
        external
        payable
        returns (address token, address curve)
    {
        if (msg.sender != router) revert NotRouter();
        return _launch(params, launchConfigId, pairToken, snipeTaxExemptions, deployer);
    }

    function _launch(Types.TokenParams calldata params, uint256 launchConfigId, address pairToken, address[] memory exemptions, address deployer)
        internal
        returns (address token, address curve)
    {
        if (hook == address(0) || graduationExecutor == address(0) || locker == address(0) || escrow == address(0) || holderFeeSharing == address(0) || launchDeployer == address(0)) revert ModulesNotSet();
        if (whitelistEnabled && !whitelisted[deployer]) revert NotWhitelisted();
        if (launchConfigId >= _configs.length) revert LaunchConfigDisabled();
        Types.LaunchConfig storage cfg = _configs[launchConfigId];
        if (!cfg.enabled) revert LaunchConfigDisabled();
        Types.PairEconomics storage econ = pairTokenEconomics[pairToken];
        if (!econ.approved) revert PairTokenNotApproved();
        if (pairToken != address(0) && IERC20(pairToken).decimals() != econ.decimals) revert PairTokenDecimalsMismatch();
        if (params.graduationVenue == Types.GraduationVenue.UniswapV4 && pairMondayOnly[pairToken]) revert PairRequiresMonday();
        if (params.graduationVenue == Types.GraduationVenue.Monday && mondayExecutor == address(0)) revert GraduationVenueUnavailable();
        if (msg.value != launchFee) revert LaunchFeeNotPaid();
        if (params.creatorTaxBps > maxCreatorTaxBps) revert CreatorTaxTooHigh();
        if (exemptions.length > MAX_EXEMPTIONS) revert ExemptionListTooLong();
        if (params.expectedEconomics != previewLaunchEconomics(launchConfigId, pairToken)) revert LaunchEconomicsMismatch();

        address creatorFeeRecipient = params.creatorFeeRecipient == address(0) ? deployer : params.creatorFeeRecipient;
        bytes32 salt = keccak256(abi.encode(deployer, params.salt));

        Types.TokenInit memory tokenInit = Types.TokenInit({
            name: params.name,
            symbol: params.symbol,
            logo: params.logo,
            description: params.description,
            socials: params.socials,
            deployer: deployer,
            holderFeeSharing: params.holderFeeSharing ? holderFeeSharing : address(0),
            supply: cfg.supply,
            initialHolder: address(this)
        });
        ILaunchDeployer deployerModule = ILaunchDeployer(launchDeployer);
        token = deployerModule.predictToken(salt, tokenInit);
        if (params.holderFeeSharing) {
            address[] memory excludedAccounts = new address[](6);
            excludedAccounts[0] = address(this);
            excludedAccounts[1] = locker;
            excludedAccounts[2] = address(poolManager);
            excludedAccounts[3] = hook;
            excludedAccounts[4] = graduationExecutor;
            excludedAccounts[5] = DEAD;
            IHolderFeeSharing(holderFeeSharing).register(token, pairToken, excludedAccounts);
        }
        if (deployerModule.deployToken(salt, tokenInit) != token) revert Create2Mismatch();

        curve = deployerModule.deployCurve(
            salt,
            Types.CurveInit({
                token: token,
                pairToken: pairToken,
                supply: cfg.supply,
                phantomQuote: econ.phantomQuote,
                graduationThreshold: econ.graduationThreshold,
                feeBps: cfg.curveFeeBps,
                creatorTaxBps: params.creatorTaxBps,
                creatorFeeRecipient: creatorFeeRecipient,
                holderFeeSharing: params.holderFeeSharing,
                deployer: deployer,
                snipeTaxSchedule: cfg.snipeTaxSchedule,
                snipeTaxExemptions: exemptions
            })
        );
        if (params.holderFeeSharing) {
            IHolderFeeSharing(holderFeeSharing).exclude(token, curve);
            IHolderFeeSharing(holderFeeSharing).setAuthorized(curve, true);
        }
        if (!IERC20(token).transfer(curve, cfg.supply)) revert Create2Mismatch();

        _launches[token] = Types.LaunchedToken({
            token: token,
            curve: curve,
            deployer: deployer,
            creatorFeeRecipient: creatorFeeRecipient,
            pairToken: pairToken,
            graduationThreshold: econ.graduationThreshold,
            creatorTaxBps: params.creatorTaxBps,
            poolFeeBps: cfg.poolFeeBps,
            tickSpacing: cfg.tickSpacing,
            holderFeeSharing: params.holderFeeSharing,
            graduationVenue: params.graduationVenue,
            phase: Types.Phase.NotGraduated,
            sweptQuote: 0,
            sweptTokens: 0,
            sweptAt: 0,
            poolId: bytes32(0),
            exists: true
        });
        _allTokens.push(token);
        curveToToken[curve] = token;
        if (msg.value > 0) IFeeEscrow(escrow).credit{value: msg.value}(protocolFeeRecipient);
        emit TokenLaunched(token, curve, deployer, pairToken, launchConfigId, econ.graduationThreshold);
    }

    // ------------------------------------------------------------------ graduation

    /// @notice Called by a curve the moment its final buy completes it. Graduation is attempted right away;
    ///         if it fails the launch is marked stuck and anyone can retry with `graduate`.
    function onCurveComplete(address token) external {
        if (msg.sender != _launches[token].curve) revert NotCurve();
        if (gasleft() < GRADUATION_GAS + GRADUATION_GAS / 32) revert InsufficientGasForGraduation();
        try this.graduate{gas: GRADUATION_GAS}(token) {}
        catch {
            if (stuckSince[token] == 0) stuckSince[token] = block.timestamp;
            emit AutoGraduationFailed(token);
        }
    }

    /// @notice Sweeps a completed curve into its Uniswap v4 pool. Anyone can call it.
    function graduate(address token) public {
        Types.LaunchedToken storage launch = _launches[token];
        if (!launch.exists) revert UnknownLaunch();
        if (launch.phase != Types.Phase.NotGraduated) revert WrongGraduationPhase();
        IBondingCurve curve = IBondingCurve(launch.curve);
        if (!curve.completed() || curve.rescued()) revert WrongGraduationPhase();

        bool useMonday = launch.graduationVenue == Types.GraduationVenue.Monday;
        address executor = useMonday ? mondayExecutor : graduationExecutor;
        if (executor == address(0)) revert GraduationVenueUnavailable();

        (uint256 quoteAmount, uint256 tokenAmount) = curve.sweep(executor);
        launch.phase = Types.Phase.Swept;
        launch.sweptQuote = quoteAmount;
        launch.sweptTokens = tokenAmount;
        launch.sweptAt = block.timestamp;
        emit LaunchSwept(token);

        // The Uniswap v4 pool levies fees through the hook, so the launch must be registered before its pool
        // initializes. Monday Trade pools use Monday's own fee tier and never touch the hook.
        if (!useMonday) {
            IMemeHook(hook).registerLaunch(
                poolKeyOf(token),
                Types.PoolLaunch({
                    token: token,
                    quoteToken: launch.pairToken,
                    tokenIsCurrency0: token < launch.pairToken,
                    creatorFeeRecipient: launch.creatorFeeRecipient,
                    feeBps: launch.poolFeeBps,
                    creatorTaxBps: launch.creatorTaxBps,
                    holderFeeSharing: launch.holderFeeSharing,
                    registered: true
                })
            );
        }
        (bytes32 poolId, uint128 liquidity) = IGraduationExecutor(executor).graduate(
            token, launch.pairToken, quoteAmount, tokenAmount, IBondingCurve(launch.curve).phantomQuote(), launch.tickSpacing
        );
        launch.phase = Types.Phase.PoolCreated;
        launch.poolId = poolId;
        stuckSince[token] = 0;
        emit PoolGraduated(token, poolId, liquidity);
    }

    /// @notice Stuck-launch valve: seven days after graduation first failed, the owner may reopen the curve for
    ///         fee-free sells so holders can exit. The launch is permanently marked Rescued.
    function rescue(address token) external onlyOwner {
        Types.LaunchedToken storage launch = _launches[token];
        if (!launch.exists) revert UnknownLaunch();
        if (launch.phase != Types.Phase.NotGraduated) revert WrongGraduationPhase();
        if (stuckSince[token] == 0 || block.timestamp < stuckSince[token] + RESCUE_DELAY) revert NotStuck();
        IBondingCurve(launch.curve).enableRescue();
        launch.phase = Types.Phase.Rescued;
        emit LaunchRescued(token);
    }

    // ------------------------------------------------------------------ creator fee recipient

    function transferCreatorFeeRecipient(address token, address newRecipient) external {
        if (msg.sender != _launches[token].creatorFeeRecipient) revert NotCreatorFeeRecipient();
        _setCreatorFeeRecipient(token, newRecipient);
    }

    /// @notice Community takeover for absent creators: public 3-day wait, then a 3-day window to execute.
    function proposeCreatorFeeRecipient(address token, address newRecipient) external onlyOwner {
        if (!_launches[token].exists) revert UnknownLaunch();
        uint256 effectiveAt = block.timestamp + TAKEOVER_DELAY;
        uint256 expiresAt = effectiveAt + TAKEOVER_WINDOW;
        pendingCreatorFeeRecipient[token] = Proposal(newRecipient, effectiveAt, expiresAt);
        emit CreatorFeeRecipientChangeProposed(token, newRecipient, effectiveAt, expiresAt);
    }

    function cancelCreatorFeeRecipientChange(address token) external onlyOwner {
        delete pendingCreatorFeeRecipient[token];
        emit CreatorFeeRecipientChangeCancelled(token);
    }

    function executeCreatorFeeRecipientChange(address token) external {
        Proposal memory p = pendingCreatorFeeRecipient[token];
        if (p.effectiveAt == 0) revert NoProposal();
        if (block.timestamp < p.effectiveAt) revert TimelockNotElapsed();
        if (block.timestamp > p.expiresAt) revert TimelockExpired();
        delete pendingCreatorFeeRecipient[token];
        _setCreatorFeeRecipient(token, p.newRecipient);
    }

    function _setCreatorFeeRecipient(address token, address newRecipient) internal {
        Types.LaunchedToken storage launch = _launches[token];
        launch.creatorFeeRecipient = newRecipient;
        IBondingCurve(launch.curve).setCreatorFeeRecipient(newRecipient);
        // Only the Uniswap v4 pool keeps a hook-side creator-fee stream to update; Monday pools have none.
        if (launch.phase == Types.Phase.PoolCreated && launch.graduationVenue == Types.GraduationVenue.UniswapV4) {
            IMemeHook(hook).setCreatorFeeRecipient(launch.poolId, newRecipient);
        }
        emit CreatorFeeRecipientUpdated(token, newRecipient);
    }

    // ------------------------------------------------------------------ views

    function launchConfigCount() external view returns (uint256) {
        return _configs.length;
    }

    function getLaunchConfig(uint256 id) external view returns (Types.LaunchConfig memory) {
        return _configs[id];
    }

    function getLaunchedToken(address token) external view returns (Types.LaunchedToken memory) {
        return _launches[token];
    }

    function getLaunchFeePolicy() external view returns (Types.FeePolicy memory) {
        return Types.FeePolicy(protocolFeeRecipient, protocolFeeShareBps);
    }

    function launchCount() external view returns (uint256) {
        return _allTokens.length;
    }

    function tokenAt(uint256 index) external view returns (address) {
        return _allTokens[index];
    }

    /// @notice Page through launches, newest last.
    /// @notice A page of launched token addresses in launch order; read each record with `getLaunchedToken`.
    function getLaunches(uint256 offset, uint256 limit) external view returns (address[] memory page) {
        uint256 n = _allTokens.length;
        if (offset >= n) return page;
        uint256 end = offset + limit > n ? n : offset + limit;
        page = new address[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            page[i - offset] = _allTokens[i];
        }
    }

    function canLaunch(address account) external view returns (bool) {
        return !whitelistEnabled || whitelisted[account];
    }

    function approvedPairTokens(address pairToken) external view returns (bool) {
        return pairTokenEconomics[pairToken].approved;
    }

    /// @notice The Uniswap v4 pool key a launch graduates into (valid once the phase is PoolCreated).
    function poolKeyOf(address token) public view returns (PoolKey memory) {
        Types.LaunchedToken storage launch = _launches[token];
        bool tokenIs0 = token < launch.pairToken;
        return PoolKey({
            currency0: Currency.wrap(tokenIs0 ? token : launch.pairToken),
            currency1: Currency.wrap(tokenIs0 ? launch.pairToken : token),
            fee: 0,
            tickSpacing: launch.tickSpacing,
            hooks: IHooks(hook)
        });
    }
}
