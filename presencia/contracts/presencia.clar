;; Presencia
;; A cross-chain presence verification protocol with multi-network rewards

(define-non-fungible-token presence-certificate uint)
(define-non-fungible-token reward-token uint)

(define-map gathering-records 
    { gathering-id: uint } 
    { 
        gathering-title: (string-ascii 50),
        gathering-timestamp: uint,
        capacity-limit: uint,
        current-participants: uint,
        reward-value: uint,
        connected-networks: (list 10 (string-ascii 20))
    }
)

(define-map participant-certificates 
    { participant: principal } 
    { earned-certificates: (list 100 uint) }
)

(define-map participant-rewards
    { participant: principal }
    { 
        total-rewards: uint,
        redeemed-rewards: uint,
        network-bonuses: (list 10 uint)
    }
)

(define-map gathering-participants
    { gathering-id: uint }
    { participants: (list 1000 principal) }
)

(define-map network-alliances
    { network-id: (string-ascii 20) }
    { reward-multiplier: uint }
)

(define-data-var certificate-counter uint u0)
(define-data-var gathering-counter uint u0)

;; Error constants
(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-CAPACITY-REACHED (err u101))
(define-constant ERR-ALREADY-REGISTERED (err u102))
(define-constant ERR-INSUFFICIENT-REWARDS (err u103))
(define-constant ERR-REWARD-CALCULATION (err u104))
(define-constant ERR-INVALID-GATHERING-DATA (err u105))
(define-constant ERR-NETWORK-UNKNOWN (err u106))
(define-constant ERR-INVALID-NETWORK-ID (err u107))

;; Validation Constants
(define-constant MAX-TITLE-LENGTH u50)
(define-constant MAX-PARTICIPANTS u1000)
(define-constant MAX-REWARD-VALUE u10000)
(define-constant MAX-NETWORKS u10)
(define-constant MAX-MULTIPLIER u5)
(define-constant MAX-NETWORK-ID-LENGTH u20)

;; Administrative Functions

(define-public (register-network-alliance 
    (network-id (string-ascii 20)) 
    (multiplier uint)
)
    (begin
        ;; Validate network-id
        (asserts! 
            (and 
                (> (len network-id) u0)
                (<= (len network-id) MAX-NETWORK-ID-LENGTH)
            ) 
            ERR-INVALID-NETWORK-ID
        )

        ;; Validate multiplier
        (asserts! 
            (and 
                (> multiplier u0)
                (<= multiplier MAX-MULTIPLIER)
            ) 
            ERR-INVALID-GATHERING-DATA
        )

        (try! (verify-admin))
        (map-set network-alliances 
            { network-id: network-id }
            { reward-multiplier: multiplier }
        )
        (ok network-id)
    )
)

(define-public (create-gathering 
    (gathering-title (string-ascii 50)) 
    (gathering-timestamp uint) 
    (capacity-limit uint) 
    (reward-value uint)
    (connected-networks (list 10 (string-ascii 20)))
)
    ;; Input validation
    (begin
        ;; Validate gathering title length
        (asserts! 
            (and 
                (> (len gathering-title) u0)
                (<= (len gathering-title) MAX-TITLE-LENGTH)
            ) 
            ERR-INVALID-GATHERING-DATA
        )

        ;; Validate network ids
        (asserts! 
            (<= (len connected-networks) MAX-NETWORKS) 
            ERR-INVALID-GATHERING-DATA
        )

        ;; Validate timestamp (ensure it's a future time)
        (asserts! (> gathering-timestamp block-height) ERR-INVALID-GATHERING-DATA)

        ;; Validate capacity limit
        (asserts! 
            (and 
                (> capacity-limit u0)
                (<= capacity-limit MAX-PARTICIPANTS)
            ) 
            ERR-INVALID-GATHERING-DATA
        )

        ;; Validate reward value
        (asserts! 
            (and 
                (> reward-value u0)
                (<= reward-value MAX-REWARD-VALUE)
            ) 
            ERR-INVALID-GATHERING-DATA
        )

        ;; Proceed with gathering creation
        (let
            ((gathering-id (+ (var-get gathering-counter) u1)))
            (try! (verify-admin))
            (map-set gathering-records 
                { gathering-id: gathering-id }
                {
                    gathering-title: gathering-title,
                    gathering-timestamp: gathering-timestamp,
                    capacity-limit: capacity-limit,
                    current-participants: u0,
                    reward-value: reward-value,
                    connected-networks: connected-networks
                }
            )
            (var-set gathering-counter gathering-id)
            (ok gathering-id)
        )
    )
)

(define-public (join-gathering (gathering-id uint))
    (let
        ((gathering (unwrap! (map-get? gathering-records { gathering-id: gathering-id }) (err u404)))
         (current-count (get current-participants gathering))
         (max-count (get capacity-limit gathering)))
        
        ;; Check if gathering is full
        (asserts! (< current-count max-count) ERR-CAPACITY-REACHED)
        
        ;; Check if participant is already registered
        (asserts! (not-already-registered tx-sender gathering-id) ERR-ALREADY-REGISTERED)
        
        ;; Mint certificate and calculate cross-network reward points
        (let
            ((certificate-id (+ (var-get certificate-counter) u1))
             (rewards-calculation (calculate-cross-network-rewards 
                 tx-sender 
                 (get reward-value gathering) 
                 (get connected-networks gathering)
             )))
            
            ;; Ensure rewards were calculated successfully
            (unwrap! rewards-calculation ERR-REWARD-CALCULATION)
            
            ;; Update certificate counter
            (var-set certificate-counter certificate-id)
            
            ;; Mint NFT certificate
            (try! (nft-mint? presence-certificate certificate-id tx-sender))
            
            ;; Update participant certificates
            (map-set participant-certificates
                { participant: tx-sender }
                { earned-certificates: (append-certificate (default-to (list ) (get earned-certificates (map-get? participant-certificates { participant: tx-sender }))) certificate-id) }
            )
            
            ;; Update gathering participants
            (map-set gathering-records 
                { gathering-id: gathering-id }
                (merge gathering { current-participants: (+ current-count u1) })
            )
            
            (ok certificate-id)
        )
    )
)

(define-public (redeem-rewards (points uint))
    (let
        ((participant-data (unwrap! (map-get? participant-rewards { participant: tx-sender }) (err u404)))
         (available-balance (- (get total-rewards participant-data) (get redeemed-rewards participant-data))))
        
        ;; Check if participant has enough points
        (asserts! (>= available-balance points) ERR-INSUFFICIENT-REWARDS)
        
        ;; Update redeemed points
        (map-set participant-rewards
            { participant: tx-sender }
            { 
                total-rewards: (get total-rewards participant-data),
                redeemed-rewards: (+ (get redeemed-rewards participant-data) points),
                network-bonuses: (get network-bonuses participant-data)
            }
        )
        
        (ok points)
    )
)

;; Helper Functions

(define-private (verify-admin)
    (ok (asserts! (is-eq tx-sender contract-caller) ERR-NOT-AUTHORIZED))
)

(define-private (not-already-registered (user principal) (gathering-id uint))
    (is-none (index-of 
        (default-to (list ) 
            (get participants (map-get? gathering-participants { gathering-id: gathering-id }))
        )
        user
    ))
)

(define-private (append-certificate (certificates (list 100 uint)) (certificate-id uint))
    (unwrap! (as-max-len? (append certificates certificate-id) u100) certificates)
)

(define-private (calculate-cross-network-rewards 
    (user principal) 
    (base-value uint)
    (gathering-networks (list 10 (string-ascii 20)))
)
    (let
        ((current-rewards (default-to 
            { 
                total-rewards: u0, 
                redeemed-rewards: u0, 
                network-bonuses: (list ) 
            } 
            (map-get? participant-rewards { participant: user })))
         (network-bonus (calculate-network-bonus gathering-networks)))
        
        (map-set participant-rewards
            { participant: user }
            {
                total-rewards: (+ 
                    (get total-rewards current-rewards) 
                    (* base-value (+ u1 network-bonus))
                ),
                redeemed-rewards: (get redeemed-rewards current-rewards),
                network-bonuses: (append-bonus 
                    (get network-bonuses current-rewards) 
                    network-bonus
                )
            }
        )
        (ok base-value)
    )
)

(define-private (calculate-network-bonus (networks (list 10 (string-ascii 20))))
    (fold 
        + 
        (map get-network-multiplier networks)
        u0
    )
)

(define-private (get-network-multiplier (network-id (string-ascii 20)))
    (default-to u0 
        (get reward-multiplier 
            (map-get? network-alliances { network-id: network-id })
        )
    )
)

(define-private (append-bonus 
    (bonuses (list 10 uint)) 
    (bonus uint)
)
    (unwrap! 
        (as-max-len? 
            (if (is-none (index-of bonuses bonus))
                (append bonuses bonus)
                bonuses
            ) 
            u10
        ) 
        bonuses
    )
)

;; Read-Only Functions

(define-read-only (get-participant-certificates (participant principal))
    (map-get? participant-certificates { participant: participant })
)

(define-read-only (get-participant-rewards (participant principal))
    (map-get? participant-rewards { participant: participant })
)

(define-read-only (get-gathering-info (gathering-id uint))
    (map-get? gathering-records { gathering-id: gathering-id })
)

(define-read-only (get-network-alliance (network-id (string-ascii 20)))
    (map-get? network-alliances { network-id: network-id })
)