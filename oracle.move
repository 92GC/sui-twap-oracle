module futarchy::oracle {
    use sui::clock::{Self, Clock};

    // ========== Constants =========
    const BASIS_POINTS: u64 = 10_000;
    const TWAP_PRICE_CAP_WINDOW_PERIOD: u64 = 60_000; // 60 seconds in milliseconds 

    // ======== Error Constants ========
    const ETIMESTAMP_REGRESSION: u64 = 0;
    const E_TWAP_NOT_STARTED: u64 = 1;
    const EZERO_PERIOD: u64 = 2;
    const EZERO_PRICE: u64 = 3;
    
    // ======== Configuration Struct ========
    public struct Oracle has key, store {
        id: UID,
        last_price: u64,
        last_timestamp: u64,
        // TWAP calculation fields - using u128 for overflow protection
        total_cumulative_price: u128,
        last_window_end_cumulative_price: u128,
        last_window_end: u64,
        last_window_twap: u64,
        twap_start_delay: u64, // Reduces attacker advantage with surprise proposals
        twap_step_max: u64,  // Maximum relative step size for TWAP calculations
        market_start_time: u64,
        twap_initialization_price: u64
    }

    // ======== Constructor ========
    public(package) fun new_oracle(
            twap_initialization_price: u64,
            market_start_time: u64,
            twap_start_delay: u64,
            twap_step_max: u64,
            ctx: &mut TxContext
        ): Oracle {
            let oracle = Oracle {
                id: object::new(ctx), // Create a unique ID for the oracle
                last_price: twap_initialization_price,
                last_timestamp: market_start_time,
                total_cumulative_price: 0,
                last_window_end_cumulative_price: 0,
                last_window_end: 0,
                last_window_twap: twap_initialization_price,
                twap_start_delay: twap_start_delay,
                twap_step_max: twap_step_max,
                market_start_time: market_start_time,
                twap_initialization_price: twap_initialization_price,
            };
        
            oracle
        }

    // ======== Helper Functions ========
    fun cap_price_change(twap_base: u64, new_price: u64, max_step: u64, full_windows_since_last_update: u64): u64 {
        // Basis points can't be 0, see calculate_decimal_scale_factor in maths module
        let steps = full_windows_since_last_update + 1;

        // Using % change consider switching to absolute change in terms of asset units
        let max_change = (twap_base * max_step * steps) / BASIS_POINTS;
        let result = if (new_price > twap_base) {
            // Cap upward movement
            if (new_price - twap_base > max_change) {
                twap_base + max_change
            } else {
                new_price
            }
        } else {
            // Cap downward movement
            if (twap_base - new_price > max_change) {
                twap_base - max_change
            } else {
                new_price
            }
        };

        result
    }

    // Calculate TWAP for the just-completed window
    fun calculate_window_twap(oracle: &Oracle, full_windows_since_last_update: u64): u64 {
        let current_window_price_accumulation = oracle.total_cumulative_price - oracle.last_window_end_cumulative_price;

        let time_elapsed = (TWAP_PRICE_CAP_WINDOW_PERIOD as u128) * (full_windows_since_last_update as u128);
        let current_window_price_sum = current_window_price_accumulation / time_elapsed;
        (current_window_price_sum as u64)
    }

    // ======== Core Functions ========
    public(package) fun write_observation(
        oracle: &mut Oracle,
        timestamp: u64,
        price: u64,
    ) {

        // Sanity time checks
        assert!(timestamp >= oracle.last_timestamp, ETIMESTAMP_REGRESSION);

        // Sanity price checks
        assert!(price > 0, EZERO_PRICE);

        // Ensure the TWAP delay has finished.
        let delay_threshold = oracle.market_start_time + oracle.twap_start_delay;
        if (timestamp < delay_threshold) {
            // Don't update TWAP during TWAP delay period

        } else {
            // If the first observation after delay arrives and last_timestamp is still below the threshold,
            // update it so that accumulation starts strictly after the delay.
            if (oracle.last_timestamp < delay_threshold) {
                oracle.last_timestamp = delay_threshold;
                oracle.last_window_end = delay_threshold;
            };

            let additional_time_to_include = timestamp - oracle.last_timestamp;

            // Avoid multiplying by 0 time. This check means that the first get_twap() caller or trader 
            // in each milisecond clock step is the only one that can impact the oracle accumulation
            if (additional_time_to_include > 0) {

                // Only update TWAP cap if entering a new window
                if (timestamp - oracle.last_window_end >= TWAP_PRICE_CAP_WINDOW_PERIOD) {
                    
                    let full_windows_since_last_update = (((timestamp - oracle.last_window_end) as u128) / (TWAP_PRICE_CAP_WINDOW_PERIOD as u128)) as u64;

                    // If multiple windows have passed, cap should all greater range of values
                    let capped_price = cap_price_change(oracle.last_window_twap, price, oracle.twap_step_max, full_windows_since_last_update);
                    
                    let scaled_price = (capped_price as u128);
                    let price_contribution = scaled_price * (additional_time_to_include as u128);
                    oracle.total_cumulative_price = oracle.total_cumulative_price + price_contribution;

                    // Add accumulation for current and previous windows
                    oracle.last_window_twap = calculate_window_twap(oracle, full_windows_since_last_update);
                    oracle.last_window_end_cumulative_price = oracle.total_cumulative_price;
                    oracle.last_window_end = oracle.last_window_end + TWAP_PRICE_CAP_WINDOW_PERIOD * full_windows_since_last_update;
                    
                    oracle.last_price = capped_price;

                // When not entering a new window
                } else {

                    let full_windows_since_last_update = 0;
                    let capped_price = cap_price_change(oracle.last_window_twap, price, oracle.twap_step_max, full_windows_since_last_update);

                    // Add accumulation for current window
                    let scaled_price = (capped_price as u128);
                    let price_contribution = scaled_price * (additional_time_to_include as u128);
                    oracle.total_cumulative_price = oracle.total_cumulative_price + price_contribution;

                    oracle.last_price = capped_price;
                };

                oracle.last_timestamp = timestamp;
            }
        }
    }

    // TWAP can only be read in same instance after a write
    // So no logic is needed to extrapolate TWAP for last write to current timestamp
    public(package) fun get_twap(oracle: &Oracle, clock: &Clock): u64 {
        let current_time = clock::timestamp_ms(clock);
        
        // Time checks
        assert!(oracle.last_timestamp != 0, ETIMESTAMP_REGRESSION);
        assert!(current_time - oracle.market_start_time >= oracle.twap_start_delay, E_TWAP_NOT_STARTED);
        assert!(current_time >= oracle.market_start_time, ETIMESTAMP_REGRESSION);
        
        // Calculate period
        let period = ( current_time - oracle.market_start_time) - oracle.twap_start_delay;
        assert!(period > 0, EZERO_PERIOD);
        
        // Calculate and validate TWAP
        let twap = (oracle.total_cumulative_price * (BASIS_POINTS as u128)) / (period as u128);
        
        (twap as u64)
    }
}
