// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title YieldClawRegistry
 * @author YieldClaw (OpenClaw Hackathon — "Most Novel Smart Contract" Track)
 * @notice Agent-Managed Yield Data Registry for USYC/Hashnote on Arc Network
 *
 * ═══════════════════════════════════════════════════════════════════════════
 * NOVEL PATTERNS DEMONSTRATED
 * ═══════════════════════════════════════════════════════════════════════════
 *
 * 1. AGENT AUTONOMY WITH ECONOMIC ACCOUNTABILITY
 *    AI agents register as yield data providers by staking USDC. This creates
 *    a skin-in-the-game incentive: agents that submit accurate data keep their
 *    stake and earn reputation; agents that submit bad data lose stake. This
 *    is a new primitive for agent-to-protocol trust without centralized KYC.
 *
 * 2. ON-CHAIN DISPUTE RESOLUTION FOR AGENT DATA
 *    Any agent can challenge another agent's yield snapshot by posting a bond.
 *    A resolution mechanism determines if the challenge is valid. If upheld,
 *    the challenger earns a reward from the submitter's stake. This creates a
 *    self-policing network of agents where bad data is economically punished.
 *
 * 3. REPUTATION SCORING FOR AUTONOMOUS AGENTS
 *    Each agent accumulates a reputation score based on their submission
 *    history and challenge outcomes. This on-chain reputation is composable —
 *    other protocols can query an agent's score before trusting its data.
 *    This is a building block for agent-to-agent trust graphs.
 *
 * 4. x402-COMPATIBLE PAID DATA QUERIES
 *    The paidQuery() function implements the x402 payment pattern on-chain:
 *    agents pay a micro-fee in USDC to access yield data. This demonstrates
 *    how agentic commerce works — autonomous agents buying and selling data
 *    with no human in the loop. Combined with the off-chain x402 endpoints,
 *    this creates a full-stack paid data marketplace for AI agents.
 *
 * 5. AGENT COORDINATION THROUGH SHARED STATE
 *    Multiple agents can submit snapshots, building a collaborative on-chain
 *    time series of yield data. Agents coordinate implicitly: each new
 *    snapshot extends the shared dataset. This pattern enables swarm
 *    intelligence — many agents contributing to a single source of truth.
 *
 * ═══════════════════════════════════════════════════════════════════════════
 * ARCHITECTURE
 * ═══════════════════════════════════════════════════════════════════════════
 *
 * Agents (AI) ──stake USDC──> Registry <──query──> Other Agents / Protocols
 *     │                          │
 *     ├── submitSnapshot()       ├── snapshots[] (on-chain time series)
 *     ├── challengeSnapshot()    ├── challenges[] (dispute log)
 *     └── paidQuery()            └── agents{} (reputation + stake)
 *
 * Vault (USYC) ── tracked by ──> Registry (stores APY, TVL, share price)
 *
 * ═══════════════════════════════════════════════════════════════════════════
 */

/// @notice Minimal ERC-20 interface for USDC interactions (approve + transferFrom pattern)
interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract YieldClawRegistry {

    // ═══════════════════════════════════════════════════════════════════════
    // STRUCTS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Represents a registered AI agent that provides yield data.
    ///         Agents must stake USDC to participate, creating economic
    ///         accountability for the data they submit.
    struct Agent {
        address addr;              // Agent's wallet address
        string name;               // Human-readable agent identifier
        uint256 reputationScore;   // Cumulative reputation (higher = more trusted)
        uint256 totalSubmissions;  // Number of yield snapshots submitted
        uint256 totalChallenges;   // Number of times this agent's data was challenged
        uint256 stakedAmount;      // Current USDC stake (slashable on bad data)
        uint256 registeredAt;      // Block timestamp of registration
        bool isActive;             // Whether the agent is currently active
    }

    /// @notice A point-in-time yield data snapshot submitted by an agent.
    ///         These form an on-chain time series that other agents and
    ///         protocols can query for historical yield analysis.
    struct YieldSnapshot {
        address submitter;         // Agent that submitted this snapshot
        uint256 timestamp;         // Block timestamp when submitted
        uint256 apy;               // Annual percentage yield in basis points (500 = 5.00%)
        uint256 tvl;               // Total value locked in USDC (6 decimals)
        uint256 sharePrice;        // USYC share price with 18 decimal precision
        uint256 blockNumber;       // Block number at submission time
        bool isDisputed;           // Whether this snapshot is under dispute
        uint256 challengeDeadline; // Timestamp after which it can no longer be challenged
    }

    /// @notice A challenge filed against a yield snapshot. Challengers must
    ///         post a bond; if the challenge is upheld the submitter is
    ///         penalised and the challenger is rewarded, creating an
    ///         economic incentive to police bad data.
    struct Challenge {
        address challenger;        // Agent that filed the challenge
        uint256 snapshotIndex;     // Index of the disputed snapshot
        uint256 bondAmount;        // USDC bond posted by the challenger
        bytes32 reason;            // Short encoded reason for the challenge
        bool resolved;             // Whether the challenge has been resolved
        bool upheld;               // Whether the challenge was found valid
    }

    // ═══════════════════════════════════════════════════════════════════════
    // STATE VARIABLES
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice The USYC ERC-4626 vault whose yield data this registry tracks
    address public vault;

    /// @notice The USDC token used for staking, bonds, and query fees
    address public usdc;

    /// @notice Registry owner, acts as simplified oracle for dispute resolution
    address public owner;

    /// @notice Minimum USDC stake required to register as an agent (10 USDC)
    uint256 public constant MIN_STAKE = 10 * 1e6;

    /// @notice USDC bond required to challenge a snapshot (5 USDC)
    uint256 public constant CHALLENGE_BOND = 5 * 1e6;

    /// @notice Window after submission during which a snapshot can be challenged
    uint256 public constant CHALLENGE_PERIOD = 1 hours;

    /// @notice Fee for x402-compatible paid data queries (0.001 USDC)
    uint256 public constant QUERY_FEE = 1000;

    /// @notice Cooldown period before a deregistered agent can withdraw stake
    uint256 public constant WITHDRAWAL_COOLDOWN = 24 hours;

    /// @notice Reputation points awarded for successful submissions
    uint256 public constant REP_SUBMISSION_BONUS = 10;

    /// @notice Reputation points awarded when a false challenge is defeated
    uint256 public constant REP_DEFENSE_BONUS = 25;

    /// @notice Reputation penalty when a challenge against the agent is upheld
    uint256 public constant REP_CHALLENGE_PENALTY = 50;

    /// @notice Lookup from address to Agent struct
    mapping(address => Agent) public agents;

    /// @notice Timestamp when a deregistered agent can withdraw their stake
    mapping(address => uint256) public withdrawalUnlockTime;

    /// @notice All yield snapshots, forming an on-chain time series
    YieldSnapshot[] public snapshots;

    /// @notice All challenges filed against snapshots
    Challenge[] public challenges;

    /// @notice Ordered list of all registered agent addresses (for iteration)
    address[] public agentList;

    /// @notice Total number of snapshots submitted
    uint256 public snapshotCount;

    /// @notice Total USDC collected from paid queries
    uint256 public totalQueryRevenue;

    // ═══════════════════════════════════════════════════════════════════════
    // EVENTS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Emitted when a new agent registers with a USDC stake
    event AgentRegistered(address indexed agent, string name);

    /// @notice Emitted when an agent submits a yield data snapshot
    event YieldSnapshotSubmitted(
        uint256 indexed index,
        address indexed submitter,
        uint256 apy,
        uint256 tvl
    );

    /// @notice Emitted when an agent challenges a snapshot's accuracy
    event SnapshotChallenged(
        uint256 indexed snapshotIndex,
        address indexed challenger
    );

    /// @notice Emitted when a challenge is resolved by the oracle
    event ChallengeResolved(uint256 indexed challengeIndex, bool upheld);

    /// @notice Emitted when an agent's reputation score changes
    event ReputationUpdated(address indexed agent, uint256 newScore);

    /// @notice Emitted when a paid query is executed via x402 pattern
    event QueryPaid(address indexed querier, uint256 amount);

    /// @notice Emitted when an agent deregisters and begins withdrawal cooldown
    event AgentDeregistered(address indexed agent, uint256 unlockTime);

    /// @notice Emitted when an agent withdraws their remaining stake
    event StakeWithdrawn(address indexed agent, uint256 amount);

    // ═══════════════════════════════════════════════════════════════════════
    // MODIFIERS
    // ═══════════════════════════════════════════════════════════════════════

    /// @notice Restricts function to the contract owner (simplified oracle)
    modifier onlyOwner() {
        require(msg.sender == owner, "YieldClaw: caller is not the owner");
        _;
    }

    /// @notice Restricts function to registered, active agents
    modifier onlyActiveAgent() {
        require(
            agents[msg.sender].isActive,
            "YieldClaw: caller is not an active agent"
        );
        _;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // CONSTRUCTOR
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Deploys the YieldClaw Registry, linking it to a specific
     *         USYC vault and USDC token on Arc Network.
     * @param _vault Address of the USYC ERC-4626 vault to track
     * @param _usdc  Address of the USDC token for staking and payments
     */
    constructor(address _vault, address _usdc) {
        require(_vault != address(0), "YieldClaw: vault is zero address");
        require(_usdc != address(0), "YieldClaw: usdc is zero address");
        vault = _vault;
        usdc = _usdc;
        owner = msg.sender;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // AGENT REGISTRATION
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Register as a yield data provider agent.
     *
     *         This is the entry point for AI agents joining the YieldClaw
     *         network. By staking USDC, the agent creates economic skin in
     *         the game: their stake can be slashed if they submit inaccurate
     *         data that is successfully challenged.
     *
     *         The agent must first approve this contract to spend at least
     *         MIN_STAKE USDC via the standard ERC-20 approve() flow.
     *
     * @param name Human-readable identifier for the agent (e.g., "YieldBot-Alpha")
     */
    function registerAgent(string calldata name) external {
        require(
            !agents[msg.sender].isActive,
            "YieldClaw: agent already registered"
        );
        require(bytes(name).length > 0, "YieldClaw: name cannot be empty");
        require(
            bytes(name).length <= 64,
            "YieldClaw: name too long (max 64 bytes)"
        );

        // Transfer stake from agent to this contract
        bool success = IERC20(usdc).transferFrom(
            msg.sender,
            address(this),
            MIN_STAKE
        );
        require(success, "YieldClaw: USDC transfer failed");

        // Create the agent record
        agents[msg.sender] = Agent({
            addr: msg.sender,
            name: name,
            reputationScore: 100, // Start with a base reputation of 100
            totalSubmissions: 0,
            totalChallenges: 0,
            stakedAmount: MIN_STAKE,
            registeredAt: block.timestamp,
            isActive: true
        });

        agentList.push(msg.sender);

        emit AgentRegistered(msg.sender, name);
    }

    /**
     * @notice Deregister an active agent. Begins the withdrawal cooldown
     *         period after which the agent can reclaim their remaining stake.
     *
     *         This allows agents to gracefully exit the network. The cooldown
     *         ensures that any pending challenges can be resolved before the
     *         agent withdraws their stake.
     */
    function deregisterAgent() external onlyActiveAgent {
        agents[msg.sender].isActive = false;
        uint256 unlockTime = block.timestamp + WITHDRAWAL_COOLDOWN;
        withdrawalUnlockTime[msg.sender] = unlockTime;

        emit AgentDeregistered(msg.sender, unlockTime);
    }

    /**
     * @notice Withdraw remaining stake after deregistration and cooldown.
     *
     *         This is the final step in the agent exit flow. The agent must
     *         have deregistered and waited through the cooldown period. Any
     *         stake that was slashed during challenges is not recoverable.
     */
    function withdrawStake() external {
        Agent storage agent = agents[msg.sender];
        require(!agent.isActive, "YieldClaw: agent is still active");
        require(agent.stakedAmount > 0, "YieldClaw: no stake to withdraw");
        require(
            block.timestamp >= withdrawalUnlockTime[msg.sender],
            "YieldClaw: withdrawal cooldown not elapsed"
        );

        uint256 amount = agent.stakedAmount;
        agent.stakedAmount = 0;

        bool success = IERC20(usdc).transfer(msg.sender, amount);
        require(success, "YieldClaw: USDC transfer failed");

        emit StakeWithdrawn(msg.sender, amount);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // YIELD DATA SUBMISSION
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Submit a yield data snapshot for the tracked USYC vault.
     *
     *         This is the core data ingestion function. AI agents read yield
     *         data from the USYC vault (APY, TVL, share price) off-chain and
     *         commit it on-chain as an immutable, timestamped record.
     *
     *         Each snapshot is subject to a challenge period during which
     *         other agents can dispute its accuracy. This creates a
     *         self-correcting data feed powered by economic incentives.
     *
     *         Novel pattern: agents act as decentralized oracles, but with
     *         stake-based accountability instead of token-weighted voting.
     *
     * @param apy        Annual percentage yield in basis points (e.g., 500 = 5.00%)
     * @param tvl        Total value locked in the vault, in USDC base units (6 decimals)
     * @param sharePrice Current share price with 18 decimal precision
     */
    function submitSnapshot(
        uint256 apy,
        uint256 tvl,
        uint256 sharePrice
    ) external onlyActiveAgent {
        require(apy <= 100_00, "YieldClaw: APY exceeds 100% (10000 bps)");
        require(tvl > 0, "YieldClaw: TVL cannot be zero");
        require(sharePrice > 0, "YieldClaw: share price cannot be zero");

        uint256 index = snapshots.length;

        snapshots.push(
            YieldSnapshot({
                submitter: msg.sender,
                timestamp: block.timestamp,
                apy: apy,
                tvl: tvl,
                sharePrice: sharePrice,
                blockNumber: block.number,
                isDisputed: false,
                challengeDeadline: block.timestamp + CHALLENGE_PERIOD
            })
        );

        // Update agent stats — every submission builds the agent's track record
        agents[msg.sender].totalSubmissions += 1;
        agents[msg.sender].reputationScore += REP_SUBMISSION_BONUS;
        snapshotCount += 1;

        emit YieldSnapshotSubmitted(index, msg.sender, apy, tvl);
        emit ReputationUpdated(
            msg.sender,
            agents[msg.sender].reputationScore
        );
    }

    // ═══════════════════════════════════════════════════════════════════════
    // CHALLENGE / DISPUTE RESOLUTION
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Challenge a yield snapshot's accuracy by posting a USDC bond.
     *
     *         This is the self-policing mechanism of the YieldClaw network.
     *         Any registered agent can challenge a snapshot they believe to
     *         be inaccurate. The challenger must post a bond (CHALLENGE_BOND)
     *         which they forfeit if the challenge is not upheld.
     *
     *         This creates a balanced incentive structure:
     *         - Submitters are incentivised to submit accurate data (or lose stake)
     *         - Challengers are incentivised to only challenge genuinely bad data
     *           (or lose their bond)
     *         - The network converges on accurate data through economic pressure
     *
     *         The caller must have approved this contract to spend CHALLENGE_BOND USDC.
     *
     * @param snapshotIndex Index of the snapshot to challenge
     * @param reason        A bytes32-encoded short reason for the challenge
     */
    function challengeSnapshot(
        uint256 snapshotIndex,
        bytes32 reason
    ) external onlyActiveAgent {
        require(
            snapshotIndex < snapshots.length,
            "YieldClaw: snapshot does not exist"
        );

        YieldSnapshot storage snapshot = snapshots[snapshotIndex];
        require(
            !snapshot.isDisputed,
            "YieldClaw: snapshot already disputed"
        );
        require(
            block.timestamp <= snapshot.challengeDeadline,
            "YieldClaw: challenge period has expired"
        );
        require(
            snapshot.submitter != msg.sender,
            "YieldClaw: cannot challenge own snapshot"
        );

        // Transfer challenge bond from challenger to this contract
        bool success = IERC20(usdc).transferFrom(
            msg.sender,
            address(this),
            CHALLENGE_BOND
        );
        require(success, "YieldClaw: USDC bond transfer failed");

        // Mark snapshot as disputed
        snapshot.isDisputed = true;

        // Record the challenge
        challenges.push(
            Challenge({
                challenger: msg.sender,
                snapshotIndex: snapshotIndex,
                bondAmount: CHALLENGE_BOND,
                reason: reason,
                resolved: false,
                upheld: false
            })
        );

        // Update submitter's challenge count
        agents[snapshot.submitter].totalChallenges += 1;

        emit SnapshotChallenged(snapshotIndex, msg.sender);
    }

    /**
     * @notice Resolve a pending challenge. Only callable by the contract owner
     *         who acts as a simplified oracle / arbitrator.
     *
     *         Resolution outcomes:
     *
     *         If UPHELD (bad data confirmed):
     *           - Challenger gets their bond back
     *           - Challenger receives half of the submitter's remaining stake
     *           - Submitter's reputation is penalised
     *
     *         If NOT UPHELD (data was accurate):
     *           - Submitter receives the challenger's bond as reward
     *           - Submitter's reputation increases (vindicated)
     *
     *         In a production system, this could be replaced by a DAO vote,
     *         an optimistic oracle (UMA), or a ZK proof of the vault state.
     *         For the hackathon, the owner acts as a trusted arbitrator.
     *
     * @param challengeIndex Index of the challenge to resolve
     * @param upheld         True if the challenge is valid (data was bad)
     */
    function resolveChallenge(
        uint256 challengeIndex,
        bool upheld
    ) external onlyOwner {
        require(
            challengeIndex < challenges.length,
            "YieldClaw: challenge does not exist"
        );

        Challenge storage challenge = challenges[challengeIndex];
        require(
            !challenge.resolved,
            "YieldClaw: challenge already resolved"
        );

        challenge.resolved = true;
        challenge.upheld = upheld;

        YieldSnapshot storage snapshot = snapshots[challenge.snapshotIndex];
        address submitter = snapshot.submitter;
        address challenger = challenge.challenger;

        if (upheld) {
            // ── Challenge upheld: the submitted data was inaccurate ──

            // Return bond to challenger
            bool bondReturn = IERC20(usdc).transfer(
                challenger,
                challenge.bondAmount
            );
            require(bondReturn, "YieldClaw: bond return failed");

            // Slash half of the submitter's stake and give it to challenger
            uint256 slashAmount = agents[submitter].stakedAmount / 2;
            if (slashAmount > 0) {
                agents[submitter].stakedAmount -= slashAmount;
                bool slashTransfer = IERC20(usdc).transfer(
                    challenger,
                    slashAmount
                );
                require(slashTransfer, "YieldClaw: slash transfer failed");
            }

            // Penalise submitter reputation
            if (agents[submitter].reputationScore > REP_CHALLENGE_PENALTY) {
                agents[submitter].reputationScore -= REP_CHALLENGE_PENALTY;
            } else {
                agents[submitter].reputationScore = 0;
            }

            emit ReputationUpdated(
                submitter,
                agents[submitter].reputationScore
            );
        } else {
            // ── Challenge not upheld: the submitted data was accurate ──

            // Award challenger's bond to the submitter as compensation
            bool bondAward = IERC20(usdc).transfer(
                submitter,
                challenge.bondAmount
            );
            require(bondAward, "YieldClaw: bond award failed");

            // Boost submitter's reputation for being vindicated
            agents[submitter].reputationScore += REP_DEFENSE_BONUS;

            emit ReputationUpdated(
                submitter,
                agents[submitter].reputationScore
            );
        }

        emit ChallengeResolved(challengeIndex, upheld);
    }

    // ═══════════════════════════════════════════════════════════════════════
    // DATA QUERIES (READ)
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Returns the most recent yield snapshot.
     *
     *         This is the primary read function for agents and protocols
     *         that need the latest yield data for the USYC vault.
     *
     * @return The latest YieldSnapshot struct
     */
    function getLatestSnapshot()
        external
        view
        returns (YieldSnapshot memory)
    {
        require(snapshots.length > 0, "YieldClaw: no snapshots available");
        return snapshots[snapshots.length - 1];
    }

    /**
     * @notice Returns a range of yield snapshots for historical analysis.
     *
     *         AI agents can use this to analyse yield trends, compute
     *         moving averages, detect anomalies, or build predictive models.
     *
     * @param from Start index (inclusive)
     * @param to   End index (exclusive)
     * @return result Array of YieldSnapshot structs in the specified range
     */
    function getSnapshotRange(
        uint256 from,
        uint256 to
    ) external view returns (YieldSnapshot[] memory result) {
        require(from < to, "YieldClaw: invalid range (from >= to)");
        require(
            to <= snapshots.length,
            "YieldClaw: range exceeds snapshot count"
        );

        uint256 length = to - from;
        result = new YieldSnapshot[](length);
        for (uint256 i = 0; i < length; i++) {
            result[i] = snapshots[from + i];
        }
        return result;
    }

    /**
     * @notice Returns full details for a registered agent.
     * @param addr The agent's wallet address
     * @return The Agent struct
     */
    function getAgent(address addr) external view returns (Agent memory) {
        require(
            agents[addr].registeredAt > 0,
            "YieldClaw: agent not found"
        );
        return agents[addr];
    }

    /**
     * @notice Returns the top agents ranked by reputation score.
     *
     *         This enables trust-aware routing: other protocols can
     *         preferentially consume data from high-reputation agents,
     *         or weight data by the submitter's reputation.
     *
     *         Uses a simple on-chain selection sort. For a small agent set
     *         (expected <100 in practice) this is gas-efficient enough.
     *         A production version could use an off-chain indexer.
     *
     * @param count Number of top agents to return
     * @return addresses Array of agent addresses, sorted by reputation (descending)
     * @return scores    Corresponding reputation scores
     */
    function getTopAgents(
        uint256 count
    )
        external
        view
        returns (address[] memory addresses, uint256[] memory scores)
    {
        uint256 total = agentList.length;
        if (count > total) {
            count = total;
        }

        // Build parallel arrays of addresses and scores
        address[] memory allAddrs = new address[](total);
        uint256[] memory allScores = new uint256[](total);

        for (uint256 i = 0; i < total; i++) {
            allAddrs[i] = agentList[i];
            allScores[i] = agents[agentList[i]].reputationScore;
        }

        // Selection sort to find the top `count` agents by reputation
        for (uint256 i = 0; i < count; i++) {
            uint256 maxIdx = i;
            for (uint256 j = i + 1; j < total; j++) {
                if (allScores[j] > allScores[maxIdx]) {
                    maxIdx = j;
                }
            }
            // Swap
            if (maxIdx != i) {
                (allAddrs[i], allAddrs[maxIdx]) = (
                    allAddrs[maxIdx],
                    allAddrs[i]
                );
                (allScores[i], allScores[maxIdx]) = (
                    allScores[maxIdx],
                    allScores[i]
                );
            }
        }

        // Trim to requested count
        addresses = new address[](count);
        scores = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            addresses[i] = allAddrs[i];
            scores[i] = allScores[i];
        }

        return (addresses, scores);
    }

    /**
     * @notice Returns the total number of snapshots submitted.
     * @return The snapshot count
     */
    function getSnapshotCount() external view returns (uint256) {
        return snapshotCount;
    }

    /**
     * @notice Returns the total number of challenges filed.
     * @return The challenge count
     */
    function getChallengeCount() external view returns (uint256) {
        return challenges.length;
    }

    /**
     * @notice Returns the total number of registered agents.
     * @return The agent count
     */
    function getAgentCount() external view returns (uint256) {
        return agentList.length;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // x402-COMPATIBLE PAID QUERY
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice x402-compatible paid data query.
     *
     *         ┌─────────────────────────────────────────────────────────────┐
     *         │  THIS IS THE x402 ON-CHAIN PATTERN:                        │
     *         │                                                            │
     *         │  1. Agent wants yield data                                 │
     *         │  2. Agent approves QUERY_FEE USDC to this contract         │
     *         │  3. Agent calls paidQuery()                                │
     *         │  4. Contract collects the fee                              │
     *         │  5. Contract returns the latest yield snapshot             │
     *         │                                                            │
     *         │  This mirrors the off-chain x402 HTTP flow:                │
     *         │    - HTTP 402 Payment Required                             │
     *         │    - Agent pays micro-amount                               │
     *         │    - Data is returned                                      │
     *         │                                                            │
     *         │  The on-chain version creates a verifiable, composable     │
     *         │  payment trail. Other contracts can build on this pattern  │
     *         │  to create data marketplaces where agents pay for access.  │
     *         └─────────────────────────────────────────────────────────────┘
     *
     *         Revenue from paid queries accumulates in the contract and
     *         could be distributed to data-providing agents as an incentive
     *         (a future enhancement).
     *
     * @return The latest YieldSnapshot
     */
    function paidQuery() external returns (YieldSnapshot memory) {
        require(snapshots.length > 0, "YieldClaw: no snapshots available");

        // Collect the query fee via ERC-20 transferFrom
        bool success = IERC20(usdc).transferFrom(
            msg.sender,
            address(this),
            QUERY_FEE
        );
        require(success, "YieldClaw: query fee transfer failed");

        totalQueryRevenue += QUERY_FEE;

        emit QueryPaid(msg.sender, QUERY_FEE);

        return snapshots[snapshots.length - 1];
    }

    /**
     * @notice Paid range query for historical yield data.
     *
     *         An extended x402 pattern — pay more for more data. The fee
     *         scales with the number of snapshots requested, incentivising
     *         efficient queries. This demonstrates how agentic commerce
     *         can price data access granularly.
     *
     * @param from Start index (inclusive)
     * @param to   End index (exclusive)
     * @return result Array of YieldSnapshot structs
     */
    function paidRangeQuery(
        uint256 from,
        uint256 to
    ) external returns (YieldSnapshot[] memory result) {
        require(from < to, "YieldClaw: invalid range (from >= to)");
        require(
            to <= snapshots.length,
            "YieldClaw: range exceeds snapshot count"
        );

        // Fee scales linearly with the number of snapshots requested
        uint256 rangeLength = to - from;
        uint256 totalFee = QUERY_FEE * rangeLength;

        bool success = IERC20(usdc).transferFrom(
            msg.sender,
            address(this),
            totalFee
        );
        require(success, "YieldClaw: query fee transfer failed");

        totalQueryRevenue += totalFee;

        emit QueryPaid(msg.sender, totalFee);

        result = new YieldSnapshot[](rangeLength);
        for (uint256 i = 0; i < rangeLength; i++) {
            result[i] = snapshots[from + i];
        }
        return result;
    }

    // ═══════════════════════════════════════════════════════════════════════
    // ADMIN / OWNER FUNCTIONS
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * @notice Transfer ownership of the registry to a new address.
     *         In a production system this could be transferred to a DAO
     *         or multisig for decentralised dispute resolution.
     * @param newOwner The new owner address
     */
    function transferOwnership(address newOwner) external onlyOwner {
        require(
            newOwner != address(0),
            "YieldClaw: new owner is zero address"
        );
        owner = newOwner;
    }

    /**
     * @notice Withdraw accumulated query revenue to the owner.
     *         In a production version, this could distribute revenue
     *         proportionally to agents based on their submission count
     *         and reputation, creating a data-provider economy.
     * @param amount Amount of USDC to withdraw
     */
    function withdrawRevenue(uint256 amount) external onlyOwner {
        require(
            amount <= totalQueryRevenue,
            "YieldClaw: insufficient revenue"
        );
        totalQueryRevenue -= amount;

        bool success = IERC20(usdc).transfer(owner, amount);
        require(success, "YieldClaw: revenue withdrawal failed");
    }
}
