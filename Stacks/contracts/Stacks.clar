;; title: nexus-consortium
;; version: 1.0.0
;; summary: Decentralized governance and collaboration platform for digital communities
;; description: A comprehensive smart contract system enabling distributed decision-making,
;;              resource allocation, and community governance through blockchain consensus
;; traits: nexus-governance-trait, consortium-member-trait

;; token definitions
(define-fungible-token nexus-token)
(define-non-fungible-token consortium-badge uint)

;; constants
(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_UNAUTHORIZED (err u100))
(define-constant ERR_INSUFFICIENT_BALANCE (err u101))
(define-constant ERR_INVALID_PROPOSAL (err u102))
(define-constant ERR_PROPOSAL_EXPIRED (err u103))
(define-constant ERR_ALREADY_VOTED (err u104))
(define-constant ERR_NOT_MEMBER (err u105))
(define-constant MIN_PROPOSAL_THRESHOLD u1000)
(define-constant VOTING_PERIOD u144) ;; blocks (~24 hours)
(define-constant QUORUM_PERCENTAGE u30)

;; data vars
(define-data-var total-nexus-supply uint u0)
(define-data-var consortium-member-count uint u0)
(define-data-var proposal-nonce uint u0)
(define-data-var governance-active bool true)
(define-data-var treasury-balance uint u0)
(define-data-var founding-epoch uint u0)

;; data maps
(define-map nexus-balances principal uint)
(define-map consortium-members principal 
  {
    tier: uint,
    joined-at: uint,
    voting-power: uint,
    reputation-score: uint,
    active-status: bool
  }
)
(define-map governance-proposals uint
  {
    proposer: principal,
    title: (string-ascii 100),
    description: (string-ascii 500),
    proposal-type: uint, ;; 1=funding, 2=parameter, 3=member, 4=governance
    target-amount: uint,
    created-at: uint,
    expires-at: uint,
    votes-for: uint,
    votes-against: uint,
    executed: bool,
    proposal-data: (optional (buff 1024))
  }
)
(define-map member-votes {proposal-id: uint, voter: principal} bool)
(define-map allocation-ledger principal uint)
(define-map reputation-multipliers uint uint) ;; tier -> multiplier
(define-map governance-parameters (string-ascii 50) uint)

;; public functions

(define-public (initialize-consortium (initial-supply uint) (founding-members (list 10 principal)))
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    (asserts! (is-eq (var-get founding-epoch) u0) ERR_UNAUTHORIZED)
    (var-set founding-epoch block-height)
    (var-set total-nexus-supply initial-supply)
    (var-set treasury-balance (/ initial-supply u2))
    (try! (ft-mint? nexus-token initial-supply CONTRACT_OWNER))
    (map bootstrap-founding-member founding-members)
    (setup-governance-parameters)
    (ok true)
  )
)

(define-public (join-consortium (tier uint))
  (let
    ((current-balance (get-nexus-balance tx-sender))
     (required-stake (get-tier-requirement tier))
     (member-id (+ (var-get consortium-member-count) u1)))
    (asserts! (>= current-balance required-stake) ERR_INSUFFICIENT_BALANCE)
    (asserts! (is-none (map-get? consortium-members tx-sender)) ERR_UNAUTHORIZED)
    (try! (ft-transfer? nexus-token required-stake tx-sender (as-contract tx-sender)))
    (map-set consortium-members tx-sender
      {
        tier: tier,
        joined-at: block-height,
        voting-power: (calculate-voting-power tier current-balance),
        reputation-score: u100,
        active-status: true
      }
    )
    (try! (nft-mint? consortium-badge member-id tx-sender))
    (var-set consortium-member-count member-id)
    (ok member-id)
  )
)

(define-public (submit-governance-proposal 
  (title (string-ascii 100))
  (description (string-ascii 500))
  (proposal-type uint)
  (target-amount uint)
  (proposal-data (optional (buff 1024))))
  (let
    ((proposal-id (+ (var-get proposal-nonce) u1))
     (member-info (unwrap! (map-get? consortium-members tx-sender) ERR_NOT_MEMBER))
     (proposer-balance (get-nexus-balance tx-sender)))
    (asserts! (get active-status member-info) ERR_NOT_MEMBER)
    (asserts! (>= proposer-balance MIN_PROPOSAL_THRESHOLD) ERR_INSUFFICIENT_BALANCE)
    (asserts! (var-get governance-active) ERR_UNAUTHORIZED)
    (map-set governance-proposals proposal-id
      {
        proposer: tx-sender,
        title: title,
        description: description,
        proposal-type: proposal-type,
        target-amount: target-amount,
        created-at: block-height,
        expires-at: (+ block-height VOTING_PERIOD),
        votes-for: u0,
        votes-against: u0,
        executed: false,
        proposal-data: proposal-data
      }
    )
    (var-set proposal-nonce proposal-id)
    (ok proposal-id)
  )
)

(define-public (cast-consortium-vote (proposal-id uint) (vote-support bool))
  (let
    ((proposal (unwrap! (map-get? governance-proposals proposal-id) ERR_INVALID_PROPOSAL))
     (member-info (unwrap! (map-get? consortium-members tx-sender) ERR_NOT_MEMBER))
     (vote-key {proposal-id: proposal-id, voter: tx-sender}))
    (asserts! (get active-status member-info) ERR_NOT_MEMBER)
    (asserts! (<= block-height (get expires-at proposal)) ERR_PROPOSAL_EXPIRED)
    (asserts! (is-none (map-get? member-votes vote-key)) ERR_ALREADY_VOTED)
    (let
      ((voting-weight (get voting-power member-info))
       (updated-proposal
         (if vote-support
           (merge proposal {votes-for: (+ (get votes-for proposal) voting-weight)})
           (merge proposal {votes-against: (+ (get votes-against proposal) voting-weight)}))))
      (map-set governance-proposals proposal-id updated-proposal)
      (map-set member-votes vote-key true)
      (ok true)
    )
  )
)

(define-public (execute-approved-proposal (proposal-id uint))
  (let
    ((proposal (unwrap! (map-get? governance-proposals proposal-id) ERR_INVALID_PROPOSAL)))
    (asserts! (> block-height (get expires-at proposal)) ERR_PROPOSAL_EXPIRED)
    (asserts! (not (get executed proposal)) ERR_INVALID_PROPOSAL)
    (asserts! (>= (get votes-for proposal) 
                  (calculate-quorum-threshold (get votes-for proposal) (get votes-against proposal))) 
              ERR_INSUFFICIENT_BALANCE)
    (map-set governance-proposals proposal-id (merge proposal {executed: true}))
    (process-proposal-execution proposal-id proposal)
  )
)

(define-public (distribute-nexus-rewards (recipients (list 20 principal)) (amounts (list 20 uint)))
  (begin
    (asserts! (is-consortium-member tx-sender) ERR_NOT_MEMBER)
    (asserts! (is-eq (len recipients) (len amounts)) ERR_INVALID_PROPOSAL)
    (map distribute-single-reward recipients amounts)
    (ok true)
  )
)

(define-public (update-member-reputation (member principal) (reputation-delta int))
  (let
    ((member-info (unwrap! (map-get? consortium-members member) ERR_NOT_MEMBER))
     (current-reputation (get reputation-score member-info))
     (new-reputation (if (>= reputation-delta 0)
                       (+ current-reputation (to-uint reputation-delta))
                       (if (>= current-reputation (to-uint (- reputation-delta)))
                         (- current-reputation (to-uint (- reputation-delta)))
                         u0))))
    (asserts! (is-consortium-member tx-sender) ERR_NOT_MEMBER)
    (map-set consortium-members member 
      (merge member-info {reputation-score: new-reputation}))
    (ok new-reputation)
  )
)

;; read only functions

(define-read-only (get-nexus-balance (account principal))
  (default-to u0 (map-get? nexus-balances account))
)

(define-read-only (get-consortium-member-info (member principal))
  (map-get? consortium-members member)
)

(define-read-only (get-proposal-details (proposal-id uint))
  (map-get? governance-proposals proposal-id)
)

(define-read-only (calculate-voting-power (tier uint) (balance uint))
  (let
    ((tier-multiplier (default-to u1 (map-get? reputation-multipliers tier)))
     (base-power (/ balance u100)))
    (* base-power tier-multiplier)
  )
)

(define-read-only (get-governance-status)
  {
    active: (var-get governance-active),
    total-members: (var-get consortium-member-count),
    total-supply: (var-get total-nexus-supply),
    treasury-balance: (var-get treasury-balance),
    current-proposals: (var-get proposal-nonce)
  }
)

(define-read-only (is-consortium-member (account principal))
  (match (map-get? consortium-members account)
    member-data (get active-status member-data)
    false
  )
)

(define-read-only (calculate-quorum-threshold (votes-for uint) (votes-against uint))
  (let
    ((total-votes (+ votes-for votes-against))
     (total-members (var-get consortium-member-count)))
    (/ (* total-members QUORUM_PERCENTAGE) u100)
  )
)

(define-read-only (get-member-voting-history (member principal) (proposal-id uint))
  (map-get? member-votes {proposal-id: proposal-id, voter: member})
)

;; private functions

(define-private (bootstrap-founding-member (member principal))
  (begin
    (map-set consortium-members member
      {
        tier: u3,
        joined-at: (var-get founding-epoch),
        voting-power: u500,
        reputation-score: u200,
        active-status: true
      }
    )
    (var-set consortium-member-count (+ (var-get consortium-member-count) u1))
  )
)

(define-private (setup-governance-parameters)
  (begin
    (map-set reputation-multipliers u1 u1)
    (map-set reputation-multipliers u2 u2)
    (map-set reputation-multipliers u3 u3)
    (map-set governance-parameters "min-proposal-threshold" MIN_PROPOSAL_THRESHOLD)
    (map-set governance-parameters "voting-period" VOTING_PERIOD)
    (map-set governance-parameters "quorum-percentage" QUORUM_PERCENTAGE)
  )
)

(define-private (get-tier-requirement (tier uint))
  (if (is-eq tier u1)
    u500
    (if (is-eq tier u2)
      u2000
      u5000
    )
  )
)

(define-private (process-proposal-execution (proposal-id uint) (proposal (tuple 
  (proposer principal)
  (title (string-ascii 100))
  (description (string-ascii 500))
  (proposal-type uint)
  (target-amount uint)
  (created-at uint)
  (expires-at uint)
  (votes-for uint)
  (votes-against uint)
  (executed bool)
  (proposal-data (optional (buff 1024))))))
  (let
    ((prop-type (get proposal-type proposal))
     (amount (get target-amount proposal))
     (proposer (get proposer proposal)))
    (if (is-eq prop-type u1) ;; funding proposal
      (begin
        (try! (ft-mint? nexus-token amount proposer))
        (var-set treasury-balance (- (var-get treasury-balance) amount))
        (ok true)
      )
      (if (is-eq prop-type u2) ;; parameter change
        (ok true) ;; implement parameter changes
        (ok true) ;; other proposal types
      )
    )
  )
)

(define-private (distribute-single-reward (recipient principal) (amount uint))
  (begin
    (try! (ft-mint? nexus-token amount recipient))
    (map-set allocation-ledger recipient 
      (+ amount (default-to u0 (map-get? allocation-ledger recipient))))
    (ok true)
  )
)