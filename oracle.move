module futarchy::oracle {
    use sui::clock::{Self, Clock};

    // ========== Constants =========
    const BASIS_POINTS: u64 = 10_000;
    const TWAP_PRICE_CAP_WINDOW: u64 = 60_000; // 60 seconds in milliseconds 

    // ======== Error Constants ========
    const ETIMESTAMP_REGRESSION: u64 = 0;
    const ETWAP_NOT_STARTED: u64 = 1;
    const EZERO_PERIOD: u64 = 2;
    const EZERO_PRICE: u64 = 3;
    const EZERO_INITIALIZATION: u64 = 4;
    const EZERO_STEP: u64 = 5;
    const ELONG_DELAY: u64 = 6;
    const ESTALE_TWAP: u64 = 7;
    
    // ======== Configuration Struct ========
    public struct Oracle has key, store {
        id: UID,
        last_price: u64,
        last_timestamp: u64,
        total_cumulative_price: u256, // TWAP calculation fields - using u256 for overflow protection
        last_window_end_cumulative_price: u256,
        last_window_end: u64,
        last_window_twap: u64,
        twap_start_delay: u64, // Reduces attacker advantage with surprise proposals
        max_bps_per_step: u64,  // Maximum relative step size for TWAP calculations
        market_start_time: u64,
        twap_initialization_price: u64
    }

    // ======== Constructor ========
    public(package) fun new_oracle(
        twap_initialization_price: u64,
        market_start_time: u64,
        twap_start_delay: u64,
        max_bps_per_step: u64,
        ctx: &mut TxContext
    ): Oracle {
        assert!(twap_initialization_price > 0, EZERO_INITIALIZATION);
        assert!(max_bps_per_step > 0, EZERO_STEP);
        assert!(twap_start_delay < 604_800_000, ELONG_DELAY); // One week in milliseconds
        
        let oracle = Oracle {
            id: object::new(ctx), // Create a unique ID for the oracle
            last_price: twap_initialization_price,
            last_timestamp: market_start_time,
            total_cumulative_price: 0,
            last_window_end_cumulative_price: 0,
            last_window_end: 0,
            last_window_twap: twap_initialization_price,
            twap_start_delay: twap_start_delay,
            max_bps_per_step: max_bps_per_step,
            market_start_time: market_start_time,
            twap_initialization_price: twap_initialization_price,
        };
    
        oracle
    }

    // ======== Helper Functions ========
    // Cap TWAP accumalation price against previous windows to stop an attacker moving it quickly
    fun cap_price_change(twap_base: u64, new_price: u64, max_bps_per_step: u64, full_windows_since_last_update: u64): u64 {
        // Calculate maximum allowed price movement as a percentage of base price
        // max_bps_per_step is in basis points (e.g., 1000 = 10%)
        let steps = full_windows_since_last_update + 1;

        // Basis points can't be 0, see calculate_decimal_scale_factor in maths module
        let computed = (twap_base * max_bps_per_step * steps) / BASIS_POINTS;
        // Ensure cap is not 0
        let max_change = if (computed < 1) { 1 } else { computed };

        // Cap upward movement
        let result = if (new_price > twap_base) {
            if (new_price - twap_base > max_change) {
                twap_base + max_change
            } else {
                new_price
            }
            
            // Cap downward movement
            } else {
                if (twap_base - new_price > max_change) {
                    twap_base - max_change
                } else {
                    new_price
                }
        };

        result
    }

    fun calculate_last_window_twap(oracle: &Oracle, full_windows_since_last_update: u64): u64 {
        let current_window_price_accumulation = oracle.total_cumulative_price - oracle.last_window_end_cumulative_price;

        let time_elapsed = (TWAP_PRICE_CAP_WINDOW as u256) * (full_windows_since_last_update as u256);
        let last_window_twap = current_window_price_accumulation / time_elapsed;
        (last_window_twap as u64)
    }

    // ======== Core Functions ========
    // Called before swaps, LP events and before reading TWAP
    public(package) fun write_observation(
        oracle: &mut Oracle,
        timestamp: u64,
        price: u64,
    ) {

        // Sanity time checks
        assert!(timestamp >= oracle.last_timestamp, ETIMESTAMP_REGRESSION);

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
            // in each millisecond clock step is the only one that can impact the oracle accumulation
            if (additional_time_to_include > 0) {

                // Close out completed TWAP window(s) and update the TWAP cap based on the last closed window's data
                if (timestamp - oracle.last_window_end >= TWAP_PRICE_CAP_WINDOW) {
                    
                    let full_windows_since_last_update = ((timestamp - oracle.last_window_end) as u256) / (TWAP_PRICE_CAP_WINDOW as u256);

                    // If multiple windows have passed, cap allows a greater range of values
                    let capped_price = cap_price_change(oracle.last_window_twap, price, oracle.max_bps_per_step, ( full_windows_since_last_update as u64));
                    
                    let scaled_price = (capped_price as u256);
                    let price_contribution = scaled_price * (additional_time_to_include as u256);
                    oracle.total_cumulative_price = oracle.total_cumulative_price + price_contribution;

                    // Add accumulation for current and previous windows
                    oracle.last_window_twap = calculate_last_window_twap(oracle, ( full_windows_since_last_update as u64));
                    oracle.last_window_end_cumulative_price = oracle.total_cumulative_price;
                    oracle.last_window_end = oracle.last_window_end + TWAP_PRICE_CAP_WINDOW * (full_windows_since_last_update as u64);
                    
                    oracle.last_price = capped_price;

                // No window closure: continue accumulating within the current open window
                } else {

                    let full_windows_since_last_update = 0;
                    let capped_price = cap_price_change(oracle.last_window_twap, price, oracle.max_bps_per_step, full_windows_since_last_update);

                    // Add accumulation for current window
                    let scaled_price = (capped_price as u256);
                    let price_contribution = scaled_price * (additional_time_to_include as u256);
                    oracle.total_cumulative_price = oracle.total_cumulative_price + price_contribution;

                    oracle.last_price = capped_price;
                };

                oracle.last_timestamp = timestamp;
            }
        }
    }

    public(package) fun get_twap(oracle: &Oracle, clock: &Clock): u64 {
        let current_time = clock::timestamp_ms(clock);

        // TWAP is only allowed to be read in the same instance, after a write has occured
        // So no logic is needed to extrapolate TWAP for last write to current timestamp
        // Check reading in same instance as last write
        assert!(current_time == oracle.last_timestamp, ESTALE_TWAP);
        
        // Time checks
        assert!(oracle.last_timestamp != 0, ETIMESTAMP_REGRESSION);
        assert!(current_time - oracle.market_start_time >= oracle.twap_start_delay, ETWAP_NOT_STARTED);
        assert!(current_time >= oracle.market_start_time, ETIMESTAMP_REGRESSION);
        
        // Calculate period
        let period = ( current_time - oracle.market_start_time) - oracle.twap_start_delay;
        assert!(period > 0, EZERO_PERIOD);
        
        // Calculate and validate TWAP
        // Multiply by BASIS_POINTS to preserve precision
        let twap = (oracle.total_cumulative_price * (BASIS_POINTS as u256)) / (period as u256);
        
        (twap as u64)
    }
}
