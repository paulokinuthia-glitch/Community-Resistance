/*==============================================================================
  EXTENDED ANALYSIS: ALTERNATIVE SPECIFICATIONS, MODEL CHECKS, AND SCDi

  Purpose: Address methodological concerns and implement Walther et al. (2023)
           Spatial Conflict Dynamics indicator

  Author: Paul Macharia
  Date: December 2025

  FIXED VERSION: Performance optimizations for large datasets

  Contents:
    Part 1: Data Setup and Variable Definitions
    Part 2: Alternative Regression Specifications (Fix violence_change issue)
    Part 3: Model Specification Checks (Overdispersion, Zero-inflation, Moran's I)
    Part 4: Robustness Checks
    Part 5: Walther et al. (2023) SCDi Implementation
    Part 6: Comparison of Clustering Measures
==============================================================================*/

clear all
set more off
capture log close

* Set working directory
cd "C:/Users/paulo/ConferenceProject"

* Define global paths
global root     "C:/Users/paulo/ConferenceProject"
global data     "$root/data"
global raw      "$data/raw"
global merged   "$data/merged"
global logs     "$root/logs"
global tables   "$root/tables"
global figures  "$root/figures"
global output   "$root/output"

* Create directories if they don't exist
capture mkdir "$logs"
capture mkdir "$tables"
capture mkdir "$figures"
capture mkdir "$output"

* Start log
log using "$logs/extended_analysis.log", replace text

display _newline(2)
display "╔═════════════════════════════════════════════════════════════╗"
display "║   EXTENDED ANALYSIS WITH ALTERNATIVE SPECIFICATIONS        ║"
display "║   AND WALTHER ET AL. (2023) SCDi IMPLEMENTATION            ║"
display "╚═════════════════════════════════════════════════════════════╝"
display _newline

set seed 20251208

/*==============================================================================
  PART 1: DATA SETUP AND VARIABLE DEFINITIONS
==============================================================================*/

display "PART 1: DATA SETUP"
display "═══════════════════════════════════════════════════════════════"

* Load your analysis data
use "$merged/analysis_data.dta", clear

* Clear any leftover temporary variables
capture drop __*

* Ensure panel structure is set
* Note: panel_id already exists from process_expanded_acled.do (numeric)
* Note: location_cluster is also numeric (from egen group)

* First check if panel_id exists
capture confirm variable panel_id
if _rc != 0 {
    * panel_id doesn't exist, create from location_cluster
    * Since location_cluster is numeric, just clone it
    gen panel_id = location_cluster
}

* Check for duplicates before xtset (avoid duplicates command which creates temp vars)
quietly count
local total_obs = r(N)
bysort panel_id ym: gen _dup_check = _n
quietly count if _dup_check > 1
local n_dups = r(N)
drop _dup_check

if `n_dups' > 0 {
    display "Warning: Found `n_dups' duplicate panel_id-ym combinations"
    display "Keeping first observation of each duplicate..."
    bysort panel_id ym: keep if _n == 1
    quietly count
    display "Observations reduced from `total_obs' to " r(N)
}

* Now set the panel
capture xtset panel_id ym
if _rc != 0 {
    display as error "ERROR: xtset failed with return code " _rc
    display as error "Attempting to diagnose..."

    * Check variable types
    describe panel_id ym

    * Check for missing values
    count if panel_id == .
    display "Missing panel_id: " r(N)
    count if ym == .
    display "Missing ym: " r(N)

    * Try after dropping missing
    drop if panel_id == . | ym == .
    xtset panel_id ym
}

* Document current variables
display "Key variables in dataset:"
capture describe violence_deaths violence_change protest_count hotspot
if _rc != 0 {
    display "Some variables may be missing, listing available:"
    describe, short
}

/*------------------------------------------------------------------------------
  1.1 Create Alternative Violence Variables
------------------------------------------------------------------------------*/

* Current specification uses: violence_change = violence(t+1) - violence(t-1)
* This creates mechanical correlation with violence_lag1

* Drop existing variables if they exist (allows re-running)
foreach v in violence_t violence_lead1 violence_lag1_alt violence_lag2 violence_lag3 ///
             protest_lag1 protest_lag2 protest_lag3 {
    capture drop `v'
}

* Alternative 1: Violence level at time t as DV
gen violence_t = violence_deaths

* Alternative 2: Violence at t+1 as DV (forward-looking)
sort panel_id ym
by panel_id: gen violence_lead1 = violence_deaths[_n+1]

* Create proper lags
by panel_id: gen violence_lag1_alt = violence_deaths[_n-1]
by panel_id: gen violence_lag2 = violence_deaths[_n-2]
by panel_id: gen violence_lag3 = violence_deaths[_n-3]

* Create protest lags
by panel_id: gen protest_lag1 = protest_count[_n-1]
by panel_id: gen protest_lag2 = protest_count[_n-2]
by panel_id: gen protest_lag3 = protest_count[_n-3]

* Label variables
label variable violence_t "Violence at time t"
label variable violence_lead1 "Violence at time t+1"
label variable violence_lag1_alt "Violence at time t-1"
label variable violence_lag2 "Violence at time t-2"
label variable violence_lag3 "Violence at time t-3"
label variable protest_lag1 "Protests at time t-1"
label variable protest_lag2 "Protests at time t-2"
label variable protest_lag3 "Protests at time t-3"

display "✓ Alternative violence variables created"

/*==============================================================================
  PART 2: ALTERNATIVE REGRESSION SPECIFICATIONS
==============================================================================*/

display _newline
display "PART 2: ALTERNATIVE REGRESSION SPECIFICATIONS"
display "═══════════════════════════════════════════════════════════════"
display _newline

/*------------------------------------------------------------------------------
  2.1 Original Specification (for comparison)
------------------------------------------------------------------------------*/

display "2.1 ORIGINAL SPECIFICATION (violence_change as DV)"
display "────────────────────────────────────────────────────────────────"

* Original model
quietly regress violence_change protest_count violence_lag1 i.hotspot
estimates store orig_ols

quietly regress violence_change c.protest_count##i.hotspot violence_lag1
estimates store orig_interact

display "Note: β for violence_lag1 ≈ -1 is largely mechanical due to"
display "      DV construction: violence_change = violence(t+1) - violence(t-1)"
display ""

/*------------------------------------------------------------------------------
  2.2 Recommended Specification: Standard Autoregressive Model
------------------------------------------------------------------------------*/

display "2.2 RECOMMENDED: Standard AR(1) Model"
display "────────────────────────────────────────────────────────────────"
display "DV = violence_t, IV = violence_lag1 (tests true autoregression)"
display ""

* Model 1: Basic AR(1) with protests
quietly regress violence_t protest_lag1 violence_lag1_alt i.hotspot
estimates store alt1_ols
display "Model 1: OLS with AR(1)"

* Model 2: With interaction
quietly regress violence_t c.protest_lag1##i.hotspot violence_lag1_alt
estimates store alt2_interact
test 1.hotspot#c.protest_lag1
local p_alt_interact = r(p)
display "Model 2: OLS with hotspot interaction, p = " %5.3f `p_alt_interact'

* Model 3: Fixed effects
quietly xtreg violence_t c.protest_lag1##i.hotspot violence_lag1_alt, fe
estimates store alt3_fe
display "Model 3: Fixed effects panel"

* Model 4: Random effects (for Hausman test)
quietly xtreg violence_t c.protest_lag1##i.hotspot violence_lag1_alt, re
estimates store alt4_re
display "Model 4: Random effects panel"

* Hausman test
quietly hausman alt3_fe alt4_re
display "Hausman test: p = " %5.3f r(p)

/*------------------------------------------------------------------------------
  2.3 Forward-Looking Specification
------------------------------------------------------------------------------*/

display _newline
display "2.3 FORWARD-LOOKING: Does protest at t predict violence at t+1?"
display "────────────────────────────────────────────────────────────────"

* Model with violence(t+1) as DV
quietly regress violence_lead1 protest_count violence_t i.hotspot if !missing(violence_lead1)
estimates store forward1_ols

quietly regress violence_lead1 c.protest_count##i.hotspot violence_t if !missing(violence_lead1)
estimates store forward2_interact
test 1.hotspot#c.protest_count
local p_forward_interact = r(p)
display "Forward model interaction p = " %5.3f `p_forward_interact'

/*------------------------------------------------------------------------------
  2.4 Compare All Specifications
------------------------------------------------------------------------------*/

display _newline
display "2.4 COMPARISON OF SPECIFICATIONS"
display "────────────────────────────────────────────────────────────────"

esttab orig_ols alt1_ols forward1_ols using "$tables/specification_comparison.csv", ///
    replace b(3) se(3) star(* 0.1 ** 0.05 *** 0.01) ///
    mtitles("Original (DV=change)" "Standard AR(1)" "Forward (DV=t+1)") ///
    stats(N r2, fmt(0 3)) ///
    title("Comparison of Violence Specifications")

esttab orig_interact alt2_interact forward2_interact, ///
    b(3) se(3) star(* 0.1 ** 0.05 *** 0.01) ///
    mtitles("Original" "Standard AR(1)" "Forward") ///
    stats(N r2, fmt(0 3))

display "✓ Alternative specifications estimated and saved"

/*==============================================================================
  PART 3: MODEL SPECIFICATION CHECKS
==============================================================================*/

display _newline(2)
display "PART 3: MODEL SPECIFICATION CHECKS"
display "═══════════════════════════════════════════════════════════════"

/*------------------------------------------------------------------------------
  3.1 Check for Overdispersion
------------------------------------------------------------------------------*/

display _newline
display "3.1 OVERDISPERSION TEST"
display "────────────────────────────────────────────────────────────────"

* Summary statistics for violence
summarize violence_t, detail
local v_mean = r(mean)
local v_var = r(Var)
local v_dispersion = `v_var' / `v_mean'

display "Mean violence: " %6.3f `v_mean'
display "Variance: " %6.3f `v_var'
display "Dispersion ratio (Var/Mean): " %6.3f `v_dispersion'

if `v_dispersion' > 1.5 {
    display "⚠ Evidence of overdispersion (ratio > 1.5)"
    display "  Recommend: Negative binomial regression"
}
else {
    display "✓ No strong evidence of overdispersion"
}

* Formal overdispersion test using auxiliary regression
* Cameron & Trivedi (1990) test
quietly poisson violence_t protest_lag1 violence_lag1_alt i.hotspot if violence_t >= 0
predict mu_hat, n
gen aux_var = ((violence_t - mu_hat)^2 - violence_t) / mu_hat
quietly regress aux_var mu_hat, nocons
display _newline "Cameron-Trivedi overdispersion test:"
display "α coefficient = " %6.3f _b[mu_hat] " (SE = " %6.3f _se[mu_hat] ")"
test mu_hat = 0
local p_overdisp = r(p)
display "H0: No overdispersion, p = " %5.3f `p_overdisp'

if `p_overdisp' < 0.05 {
    display "⚠ Reject H0: Evidence of overdispersion"
}

drop mu_hat aux_var

/*------------------------------------------------------------------------------
  3.2 Negative Binomial vs Poisson Comparison

  FIX: Use sampling for large datasets and add convergence options
------------------------------------------------------------------------------*/

display _newline
display "3.2 NEGATIVE BINOMIAL VS POISSON"
display "────────────────────────────────────────────────────────────────"

* Ensure non-negative integer outcome
capture drop violence_count
gen violence_count = max(0, round(violence_t))

* Check dataset size and use sampling if needed
quietly count
local n_obs = r(N)
local use_sample = (`n_obs' > 500000)

if `use_sample' {
    display "Large dataset detected (N = `n_obs')"
    display "Using 10% stratified sample for NB/Poisson comparison..."

    * Create stratified sample (preserve variation in outcome)
    preserve

    * Stratify by hotspot and whether violence occurred
    gen violence_any = (violence_count > 0)
    set seed 20251208

    * Sample 10% within each stratum
    bysort hotspot violence_any: gen _sample_u = runiform()
    bysort hotspot violence_any: egen _sample_p10 = pctile(_sample_u), p(10)
    keep if _sample_u <= _sample_p10
    drop _sample_u _sample_p10 violence_any

    quietly count
    display "Sample size: " r(N)
}

* Poisson model
display "Estimating Poisson model..."
quietly poisson violence_count protest_lag1 violence_lag1_alt i.hotspot
estimates store pois_model
local ll_pois = e(ll)

* Negative binomial model with convergence options
display "Estimating Negative Binomial model..."
display "  (with iteration limit and difficult option)"

* Use GLM with NB family - often more stable than nbreg
capture noisily glm violence_count protest_lag1 violence_lag1_alt i.hotspot, ///
    family(nbinomial) link(log) iterate(50) difficult

if _rc == 0 {
    estimates store nbreg_model
    local ll_nbreg = e(ll)

    * Get alpha from GLM (stored differently)
    local alpha = e(k_aux)

    * Likelihood ratio test
    local lr_stat = 2 * (`ll_nbreg' - `ll_pois')
    local p_lr = chi2tail(1, max(0, `lr_stat'))

    display "Poisson log-likelihood: " %10.2f `ll_pois'
    display "Neg Binomial log-likelihood: " %10.2f `ll_nbreg'
    display "LR test statistic: " %6.2f `lr_stat'
    display "LR test p-value: " %6.4f `p_lr'

    if `p_lr' < 0.05 {
        display "⚠ Negative binomial preferred over Poisson"
    }

    * NB with interaction (also using GLM)
    capture noisily glm violence_count c.protest_lag1##i.hotspot violence_lag1_alt, ///
        family(nbinomial) link(log) iterate(50) difficult
    if _rc == 0 {
        estimates store nbreg_interact
    }
}
else {
    display "Note: GLM NB failed, trying nbreg with constraints..."

    * Try nbreg with strict iteration limits
    capture noisily nbreg violence_count protest_lag1 violence_lag1_alt i.hotspot, ///
        iterate(30) difficult ltolerance(1e-4)

    if _rc == 0 {
        estimates store nbreg_model
        local ll_nbreg = e(ll)
        local alpha = e(alpha)

        local lr_stat = 2 * (`ll_nbreg' - `ll_pois')
        local p_lr = chi2tail(1, max(0, `lr_stat'))

        display "Poisson log-likelihood: " %10.2f `ll_pois'
        display "Neg Binomial log-likelihood: " %10.2f `ll_nbreg'
        display "Alpha (dispersion): " %6.3f `alpha'
        display "LR test statistic: " %6.2f `lr_stat'
        display "LR test p-value: " %6.4f `p_lr'
    }
    else {
        display "Warning: Negative binomial model did not converge"
        display "This is common with extreme overdispersion (ratio = `v_dispersion')"
        display "Proceeding with Poisson + robust SEs as alternative"

        * Use Poisson with robust standard errors instead
        quietly poisson violence_count protest_lag1 violence_lag1_alt i.hotspot, vce(robust)
        estimates store pois_robust
        display "✓ Poisson with robust SEs estimated as alternative"
    }
}

if `use_sample' {
    restore
    display "Restored full dataset"
}

/*------------------------------------------------------------------------------
  3.3 Zero-Inflation Check

  FIX: Use sampling for ZINB model
------------------------------------------------------------------------------*/

display _newline
display "3.3 ZERO-INFLATION CHECK"
display "────────────────────────────────────────────────────────────────"

* Count zeros
count if violence_count == 0
local n_zeros = r(N)
count if !missing(violence_count)
local n_total = r(N)
local pct_zeros = 100 * `n_zeros' / `n_total'

display "Observations with zero violence: " `n_zeros' " (" %4.1f `pct_zeros' "%)"

* Expected zeros under Poisson
quietly poisson violence_count protest_lag1 violence_lag1_alt i.hotspot
predict p_zero, pr(0)
summarize p_zero
local expected_zeros = r(mean) * `n_total'

display "Expected zeros under Poisson: " %8.0f `expected_zeros'
display "Observed zeros: " `n_zeros'

local excess_zero_ratio = `n_zeros' / `expected_zeros'

if `excess_zero_ratio' > 1.2 {
    display "⚠ Excess zeros detected (observed/expected = " %4.2f `excess_zero_ratio' ")"
    display "  Consider zero-inflated models"

    * Only try ZINB on a sample for large datasets
    if `n_obs' > 200000 {
        display "  Using 5% sample for ZINB estimation..."

        preserve
        sample 5

        capture noisily zinb violence_count protest_lag1 violence_lag1_alt i.hotspot, ///
            inflate(hotspot) iterate(30) difficult

        if _rc == 0 {
            estimates store zinb_model
            display "Zero-inflated NB model estimated successfully (on sample)"
        }
        else {
            display "ZINB did not converge - this is common with sparse data"
        }

        restore
    }
    else {
        capture noisily zinb violence_count protest_lag1 violence_lag1_alt i.hotspot, ///
            inflate(hotspot) iterate(50)
        if _rc == 0 {
            estimates store zinb_model
            display "Zero-inflated NB model estimated successfully"
        }
    }
}
else {
    display "✓ Zero proportion consistent with count model expectations"
}

drop p_zero

/*------------------------------------------------------------------------------
  3.4 Moran's I for Spatial Autocorrelation in Residuals
------------------------------------------------------------------------------*/

display _newline
display "3.4 SPATIAL AUTOCORRELATION (Moran's I)"
display "────────────────────────────────────────────────────────────────"

* Get residuals from main model
* Drop existing variables if they exist
capture drop resid resid_group_mean resid_deviation n_in_group resid_others_mean

quietly regress violence_t protest_lag1 violence_lag1_alt i.hotspot
predict resid, residuals

* Simpler approach: Calculate spatial correlation of residuals by country-month
* (Approximation - for full Moran's I, use spatwmat package)

* Method 1: Within-group spatial correlation
bysort country ym: egen resid_group_mean = mean(resid)
gen resid_deviation = resid - resid_group_mean

* Calculate correlation between location residuals and their group means
* (excludes own observation)
bysort country ym: gen n_in_group = _N
gen resid_others_mean = (resid_group_mean * n_in_group - resid) / (n_in_group - 1) if n_in_group > 1

corr resid resid_others_mean if n_in_group > 1
local moran_approx = r(rho)

display "Approximate spatial correlation of residuals: " %5.3f `moran_approx'

if abs(`moran_approx') > 0.1 {
    display "⚠ Evidence of spatial autocorrelation in residuals"
    display "  Consider spatial regression models or cluster-robust SEs"
}
else {
    display "✓ Limited evidence of spatial autocorrelation"
}

* Method 2: Distance-based spatial lag (for locations with coordinates)
* Create a proper spatial lag using preserve/restore
* FIX: Limit to unique locations to avoid memory issues

preserve
    * Get mean residual and coordinates by location
    collapse (mean) resid_loc=resid latitude longitude, by(panel_id)

    * Count locations
    quietly count
    local n_locs = r(N)
    display "Calculating spatial weights for `n_locs' locations..."

    * If too many locations, sample for this diagnostic
    if `n_locs' > 10000 {
        display "  Sampling 10,000 locations for spatial correlation..."
        sample 10000, count
        local n_locs = 10000
    }

    * Generate spatial lag manually (within 0.5 degrees ≈ 50km)
    gen spatial_lag_resid = .

    * Create a temporary copy with renamed variables for matching
    gen loc_id = _n

    tempfile master_locs
    save `master_locs'

    * Rename for using file
    rename (panel_id latitude longitude resid_loc loc_id) ///
           (panel_id2 lat2 lon2 resid2 loc_id2)

    tempfile using_locs
    save `using_locs'

    * Reload master and cross
    use `master_locs', clear
    cross using `using_locs'

    * Calculate distance (in degrees, ~111km per degree)
    gen distance = sqrt((latitude - lat2)^2 + (longitude - lon2)^2)

    * Define neighbors (within 0.5 degrees, excluding self)
    gen is_neighbor = (distance > 0 & distance < 0.5)

    * Calculate spatial lag of residuals
    bysort loc_id: egen neighbor_resid_sum = total(resid2 * is_neighbor)
    bysort loc_id: egen n_neighbors = total(is_neighbor)

    gen spatial_lag = neighbor_resid_sum / n_neighbors if n_neighbors > 0

    * Keep one row per location
    bysort loc_id: keep if _n == 1

    * Calculate Moran's I approximation
    corr resid_loc spatial_lag if n_neighbors > 0
    local moran_distance = r(rho)

    display ""
    display "Distance-based spatial correlation: " %5.3f `moran_distance'
    display "  (neighbors within ~50km)"

restore

* Clean up temporary variables
capture drop resid resid_group_mean resid_deviation n_in_group resid_others_mean

/*==============================================================================
  PART 4: ROBUSTNESS CHECKS
==============================================================================*/

display _newline(2)
display "PART 4: ROBUSTNESS CHECKS"
display "═══════════════════════════════════════════════════════════════"

/*------------------------------------------------------------------------------
  4.1 Alternative Hotspot Definitions
------------------------------------------------------------------------------*/

display _newline
display "4.1 ALTERNATIVE HOTSPOT DEFINITIONS"
display "────────────────────────────────────────────────────────────────"

* Current hotspot: meets 2 of 3 criteria (top 25% avg, top 5% max, top 25% CV)

* Drop existing variables if they exist
foreach v in avg_violence_loc hotspot_strict hotspot_loose total_events hotspot_events {
    capture drop `v'
}

* Alternative 1: More restrictive (top 10% persistent)
bysort panel_id: egen avg_violence_loc = mean(violence_t)
quietly summarize avg_violence_loc, detail
local p90_val = r(p90)
gen hotspot_strict = (avg_violence_loc >= `p90_val')

* Alternative 2: Less restrictive (top 33% persistent)
* FIX: Use _pctile to get 67th percentile (summarize only stores p1,p5,p10,p25,p50,p75,p90,p95,p99)
quietly _pctile avg_violence_loc, p(67)
local p67_val = r(r1)
gen hotspot_loose = (avg_violence_loc >= `p67_val')

* Alternative 3: Based on event counts only
bysort panel_id: egen total_events = total(violence_count)
quietly summarize total_events, detail
local p75_events = r(p75)
gen hotspot_events = (total_events >= `p75_events')

label variable hotspot_strict "Hotspot (top 10%)"
label variable hotspot_loose "Hotspot (top 33%)"
label variable hotspot_events "Hotspot (event count)"

* Verify variation in each hotspot definition
display "Checking variation in hotspot definitions:"
foreach def in hotspot hotspot_strict hotspot_loose hotspot_events {
    quietly summarize `def'
    display "  `def': mean = " %5.3f r(mean) " (N=1: " %8.0f r(mean)*r(N) ")"
}

* Run models with each definition
foreach def in hotspot hotspot_strict hotspot_loose hotspot_events {
    * Check if variable has variation before running regression
    quietly summarize `def'
    if r(sd) == 0 {
        display "`def': No variation - skipping"
        continue
    }

    capture quietly regress violence_t c.protest_lag1##i.`def' violence_lag1_alt
    if _rc != 0 {
        display "`def': Regression failed - skipping"
        continue
    }
    estimates store rob_`def'

    capture test 1.`def'#c.protest_lag1
    if _rc == 0 {
        display "`def' interaction p = " %5.3f r(p)
    }
    else {
        display "`def': Interaction test not available"
    }
}

* Export results (capture in case some models weren't estimated)
capture noisily esttab rob_hotspot rob_hotspot_strict rob_hotspot_loose rob_hotspot_events ///
    using "$tables/robustness_hotspot_definitions.csv", replace ///
    b(3) se(3) star(* 0.1 ** 0.05 *** 0.01) ///
    mtitles("Baseline (2/3)" "Strict (10%)" "Loose (33%)" "Events") ///
    stats(N r2, fmt(0 3))

if _rc != 0 {
    display "Note: Some models could not be exported - check which estimates exist"
}

/*------------------------------------------------------------------------------
  4.2 Different Lag Structures
------------------------------------------------------------------------------*/

display _newline
display "4.2 DIFFERENT LAG STRUCTURES"
display "────────────────────────────────────────────────────────────────"

* 1-month lag (baseline)
quietly regress violence_t c.protest_lag1##i.hotspot violence_lag1_alt
estimates store lag1
test 1.hotspot#c.protest_lag1
display "1-month lag: interaction p = " %5.3f r(p)

* 2-month lag
quietly regress violence_t c.protest_lag2##i.hotspot violence_lag1_alt
estimates store lag2
test 1.hotspot#c.protest_lag2
display "2-month lag: interaction p = " %5.3f r(p)

* 3-month lag
quietly regress violence_t c.protest_lag3##i.hotspot violence_lag1_alt
estimates store lag3
test 1.hotspot#c.protest_lag3
display "3-month lag: interaction p = " %5.3f r(p)

* Cumulative lag (sum of past 3 months)
capture drop protest_cumulative
gen protest_cumulative = protest_lag1 + protest_lag2 + protest_lag3
quietly regress violence_t c.protest_cumulative##i.hotspot violence_lag1_alt
estimates store lag_cum
test 1.hotspot#c.protest_cumulative
display "Cumulative (3-month) lag: interaction p = " %5.3f r(p)

esttab lag1 lag2 lag3 lag_cum using "$tables/robustness_lag_structures.csv", replace ///
    b(3) se(3) star(* 0.1 ** 0.05 *** 0.01) ///
    mtitles("1-month" "2-month" "3-month" "Cumulative") ///
    stats(N r2, fmt(0 3))

/*------------------------------------------------------------------------------
  4.3 Country-by-Country Analysis
------------------------------------------------------------------------------*/

display _newline
display "4.3 COUNTRY-BY-COUNTRY ANALYSIS"
display "────────────────────────────────────────────────────────────────"

levelsof country, local(countries)

foreach c of local countries {
    display _newline "Country: `c'"

    capture quietly regress violence_t c.protest_lag1##i.hotspot violence_lag1_alt ///
        if country == "`c'"

    if _rc == 0 {
        estimates store country_`=subinstr("`c'"," ","_",.)'

        test 1.hotspot#c.protest_lag1
        if r(p) != . {
            display "  Interaction p = " %5.3f r(p)
        }
        else {
            display "  Interaction test not available (insufficient variation)"
        }

        display "  N = " e(N) ", R2 = " %5.3f e(r2)
    }
    else {
        display "  Model failed to converge"
    }
}

/*------------------------------------------------------------------------------
  4.4 Different Spillover Radii
------------------------------------------------------------------------------*/

display _newline
display "4.4 DIFFERENT SPILLOVER RADII"
display "────────────────────────────────────────────────────────────────"

* Create spatial lags at different radii
* Note: Assumes latitude/longitude available in data
* FIX: Simplified approach - calculate at location level first

display "Note: Spatial spillover analysis uses simplified neighbor counts"
display "      For full spatial econometrics, consider sppack or spreg"

* For now, use the existing spatial lag if available
capture confirm variable spatial_lag_violence
if _rc == 0 {
    display "Using existing spatial lag variable"

    quietly regress violence_t protest_lag1 violence_lag1_alt spatial_lag_violence i.hotspot
    estimates store spillover_base
}
else {
    display "No spatial lag variable found - skipping spillover analysis"
}

/*==============================================================================
  PART 5: WALTHER ET AL. (2023) SCDi IMPLEMENTATION
==============================================================================*/

display _newline(2)
display "PART 5: WALTHER ET AL. (2023) SCDi IMPLEMENTATION"
display "═══════════════════════════════════════════════════════════════"
display _newline

/*------------------------------------------------------------------------------
  5.1 Define Grid Cells (50km x 50km as in Walther et al.)
------------------------------------------------------------------------------*/

display "5.1 CREATING GRID CELLS"
display "────────────────────────────────────────────────────────────────"

* Convert lat/lon to approximate km grid
* 1 degree latitude ≈ 111 km
* 1 degree longitude ≈ 111 * cos(latitude) km

* Drop existing variables if they exist
foreach v in grid_lat grid_lon grid_cell cell_area_km2 {
    capture drop `v'
}

* Create grid cells of approximately 50km x 50km (≈ 0.45 degrees)
local grid_size = 0.45  // degrees

gen grid_lat = floor(latitude / `grid_size') * `grid_size'
gen grid_lon = floor(longitude / `grid_size') * `grid_size'
egen grid_cell = group(grid_lat grid_lon)

* Calculate cell area in km^2
gen cell_area_km2 = (`grid_size' * 111) * (`grid_size' * 111 * cos(latitude * _pi / 180))

label variable grid_cell "50km grid cell ID"
label variable cell_area_km2 "Grid cell area (km^2)"

quietly distinct grid_cell
local n_grid_cells = r(ndistinct)
display "Number of grid cells: `n_grid_cells'"

/*------------------------------------------------------------------------------
  5.2 Calculate Conflict Intensity (CI) - Walther et al. Eq. 1
------------------------------------------------------------------------------*/

display _newline
display "5.2 CONFLICT INTENSITY (CI)"
display "────────────────────────────────────────────────────────────────"
display "CI = Number of events / Area (events per km^2)"
display ""

* Calculate events per grid-cell-year
capture drop year_scdi
gen year_scdi = year(dofm(ym))

* Aggregate events to grid-cell-year
preserve
    collapse (sum) violence_events_sum = violence_count ///
             (mean) cell_area = cell_area_km2, ///
             by(grid_cell year_scdi country)

    * Calculate Conflict Intensity
    gen conflict_intensity = violence_events_sum / cell_area

    label variable conflict_intensity "Conflict Intensity (events/km^2)"

    * Calculate "generational mean" as in Walther et al.
    summarize conflict_intensity if conflict_intensity > 0, detail
    local ci_gen_mean = r(mean)

    * Classify as high/low intensity
    gen high_intensity = (conflict_intensity > `ci_gen_mean')

    display "Generational mean CI: " %8.6f `ci_gen_mean'
    tabulate high_intensity

    tempfile ci_data
    save `ci_data'
restore

* Merge CI back to main data
merge m:1 grid_cell year_scdi country using `ci_data', nogen

/*------------------------------------------------------------------------------
  5.3 Calculate Conflict Concentration (CC) - Walther et al. Eq. 2-3

  FIX: Vectorized approach instead of row-by-row loop
       Uses aggregation instead of O(n^2) pairwise calculations
------------------------------------------------------------------------------*/

display _newline
display "5.3 CONFLICT CONCENTRATION (CC) - Average Nearest Neighbor"
display "────────────────────────────────────────────────────────────────"
display "ANN = Observed mean distance / Expected mean distance"
display "Expected = 0.5 / sqrt(n/A)"
display "ANN < 1 = clustered, ANN > 1 = dispersed"
display ""

* This requires event-level data with coordinates
* FIX: Use a scalable approximation instead of pairwise distances

preserve
    * Aggregate to unique location-year combinations with event counts
    collapse (sum) n_events = violence_count ///
             (mean) latitude longitude cell_area_km2, ///
             by(grid_cell year_scdi panel_id)

    * Keep only location-years with events
    keep if n_events > 0

    * For each grid-cell-year, calculate statistics
    bysort grid_cell year_scdi: gen n_locations_with_events = _N
    bysort grid_cell year_scdi: egen total_events_cell = total(n_events)

    * Calculate centroid of events within each grid-cell-year
    bysort grid_cell year_scdi: egen mean_lat = mean(latitude)
    bysort grid_cell year_scdi: egen mean_lon = mean(longitude)

    * Calculate average distance from centroid (proxy for dispersion)
    gen dist_from_centroid = sqrt((latitude - mean_lat)^2 + (longitude - mean_lon)^2) * 111
    bysort grid_cell year_scdi: egen avg_dist_centroid = mean(dist_from_centroid)

    * Calculate standard distance (spatial standard deviation)
    gen dist_sq = dist_from_centroid^2
    bysort grid_cell year_scdi: egen var_dist = mean(dist_sq)
    gen std_distance = sqrt(var_dist)

    * Expected distance under random distribution
    * For uniform distribution in circle: E[d] ≈ 0.52 * sqrt(A/pi)
    * For square: E[d] ≈ 0.52 * sqrt(A)
    gen expected_dist = 0.52 * sqrt(cell_area_km2)

    * Conflict Concentration approximation (inverse of dispersion)
    * Lower values = more clustered
    gen conflict_concentration = avg_dist_centroid / expected_dist if n_locations_with_events >= 2

    * For cells with only 1 event location, set to 0 (maximally concentrated)
    replace conflict_concentration = 0 if n_locations_with_events == 1

    * Classify as clustered or dispersed
    gen clustered = (conflict_concentration < 1) if !missing(conflict_concentration)
    gen dispersed = (conflict_concentration >= 1) if !missing(conflict_concentration)

    * Collapse to grid-cell-year level
    collapse (mean) conflict_concentration avg_dist_centroid std_distance ///
             (first) clustered dispersed n_locations_with_events total_events_cell, ///
             by(grid_cell year_scdi)

    label variable conflict_concentration "Conflict Concentration (dispersion ratio)"
    label variable clustered "Events clustered (CC < 1)"
    label variable dispersed "Events dispersed (CC >= 1)"

    * Summary statistics
    summarize conflict_concentration, detail
    display "Mean CC: " %5.3f r(mean)
    display "Median CC: " %5.3f r(p50)
    tabulate clustered if !missing(clustered)

    tempfile cc_data
    save `cc_data'
restore

* Merge CC back to main data
capture drop conflict_concentration clustered dispersed
merge m:1 grid_cell year_scdi using `cc_data', nogen keepusing(conflict_concentration clustered dispersed)

/*------------------------------------------------------------------------------
  5.4 Create SCDi Typology (4 categories)
------------------------------------------------------------------------------*/

display _newline
display "5.4 SCDi TYPOLOGY"
display "────────────────────────────────────────────────────────────────"
display "Type 1: High intensity + Clustered"
display "Type 2: High intensity + Dispersed"
display "Type 3: Low intensity + Clustered"
display "Type 4: Low intensity + Dispersed"
display ""

* Create typology variable
capture drop scdi_type
gen scdi_type = .
replace scdi_type = 1 if high_intensity == 1 & clustered == 1
replace scdi_type = 2 if high_intensity == 1 & dispersed == 1
replace scdi_type = 3 if high_intensity == 0 & clustered == 1
replace scdi_type = 4 if high_intensity == 0 & dispersed == 1

label define scdi_lbl 1 "High-Clustered" 2 "High-Dispersed" ///
                       3 "Low-Clustered" 4 "Low-Dispersed", replace
label values scdi_type scdi_lbl
label variable scdi_type "SCDi Typology (Walther et al.)"

* Tabulate
tabulate scdi_type, missing
tabulate scdi_type country, row nofreq

/*==============================================================================
  PART 6: COMPARISON OF CLUSTERING MEASURES
==============================================================================*/

display _newline(2)
display "PART 6: COMPARISON OF CLUSTERING MEASURES"
display "═══════════════════════════════════════════════════════════════"

/*------------------------------------------------------------------------------
  6.1 Compare Your Hotspot with SCDi Categories
------------------------------------------------------------------------------*/

display _newline
display "6.1 HOTSPOT VS SCDi COMPARISON"
display "────────────────────────────────────────────────────────────────"

* Cross-tabulation
tabulate hotspot scdi_type, chi2

* Correlation
capture corr hotspot high_intensity clustered
if _rc == 0 {
    display ""
    display "Your hotspot measure captures locations that are:"
    tabulate scdi_type if hotspot == 1, missing
}

/*------------------------------------------------------------------------------
  6.2 Compare Burstiness with SCDi
------------------------------------------------------------------------------*/

display _newline
display "6.2 BURSTINESS VS SCDi"
display "────────────────────────────────────────────────────────────────"

* Correlation between burstiness and SCDi measures
capture confirm variable burstiness_violence
if _rc == 0 {
    corr burstiness_violence conflict_intensity conflict_concentration

    * Average burstiness by SCDi type
    tabstat burstiness_violence, by(scdi_type) stat(mean sd n)
}
else {
    display "Burstiness variable not found - skipping"
}

/*------------------------------------------------------------------------------
  6.3 Regression with Both Measures
------------------------------------------------------------------------------*/

display _newline
display "6.3 REGRESSION WITH BOTH MEASURES"
display "────────────────────────────────────────────────────────────────"

* Model with your hotspot
quietly regress violence_t c.protest_lag1##i.hotspot violence_lag1_alt
estimates store model_hotspot
test 1.hotspot#c.protest_lag1
local p_hotspot = r(p)
display "Model with Hotspot: Interaction p = " %5.3f `p_hotspot'

* Model with SCDi high intensity
capture {
    quietly regress violence_t c.protest_lag1##i.high_intensity violence_lag1_alt
    estimates store model_scdi_int
    test 1.high_intensity#c.protest_lag1
    display "Model with SCDi Intensity: Interaction p = " %5.3f r(p)
}

* Model with SCDi clustering
capture {
    quietly regress violence_t c.protest_lag1##i.clustered violence_lag1_alt
    estimates store model_scdi_clust
    test 1.clustered#c.protest_lag1
    display "Model with SCDi Clustering: Interaction p = " %5.3f r(p)
}

* Model with full SCDi typology
capture {
    quietly regress violence_t c.protest_lag1##i.scdi_type violence_lag1_alt
    estimates store model_scdi_full
    testparm i.scdi_type#c.protest_lag1
    display "Model with SCDi Typology: Joint interaction p = " %5.3f r(p)
}

* Compare models (only if all estimated successfully)
capture {
    esttab model_hotspot model_scdi_int model_scdi_clust using ///
        "$tables/hotspot_vs_scdi.csv", replace ///
        b(3) se(3) star(* 0.1 ** 0.05 *** 0.01) ///
        mtitles("Your Hotspot" "SCDi Intensity" "SCDi Clustering") ///
        stats(N r2, fmt(0 3))
}

/*==============================================================================
  FINAL SUMMARY
==============================================================================*/

display _newline(3)
display "╔═════════════════════════════════════════════════════════════╗"
display "║   EXTENDED ANALYSIS COMPLETE                                ║"
display "╚═════════════════════════════════════════════════════════════╝"
display _newline

display "SUMMARY OF KEY FINDINGS:"
display "═══════════════════════════════════════════════════════════════"
display ""
display "1. SPECIFICATION CHECK:"
display "   Original DV (violence_change) creates mechanical β ≈ -1"
display "   Alternative specification (violence_t ~ violence_t-1) recommended"
display ""
display "2. MODEL DIAGNOSTICS:"
display "   Overdispersion ratio: " %5.2f `v_dispersion'
display "   Zero proportion: " %4.1f `pct_zeros' "%"
display "   Spatial autocorrelation: " %5.3f `moran_approx'
display ""
display "3. SCDi IMPLEMENTATION:"
display "   Grid cells created: `n_grid_cells'"
display "   Conflict Intensity calculated (events/km^2)"
display "   Conflict Concentration calculated (centroid-based)"
display "   4-category typology created"
display ""
display "OUTPUTS SAVED:"
display "   $tables/specification_comparison.csv"
display "   $tables/robustness_hotspot_definitions.csv"
display "   $tables/robustness_lag_structures.csv"
display "   $tables/hotspot_vs_scdi.csv"

* Save enhanced dataset
save "$merged/analysis_data_extended.dta", replace
display ""
display "✓ Extended analysis data saved: $merged/analysis_data_extended.dta"

log close

/*==============================================================================
  END OF DO-FILE
==============================================================================*/
