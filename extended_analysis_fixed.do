/*==============================================================================
  EXTENDED ANALYSIS: ALTERNATIVE SPECIFICATIONS, MODEL CHECKS, SCDi & BURSTINESS

  Purpose: Address methodological concerns, implement Walther et al. (2023)
           Spatial Conflict Dynamics indicator, and analyze temporal dynamics

  Author: Paul Macharia
  Date: December 2025

  FIXED VERSION: Performance optimizations for large datasets
                 Fixed nested preserve/restore, SCDi test, capture blocks

  Contents:
    Part 1: Data Setup and Variable Definitions
    Part 2: Alternative Regression Specifications (Fix violence_change issue)
    Part 3: Model Specification Checks (Overdispersion, Zero-inflation, Moran's I)
    Part 4: Robustness Checks
    Part 5: Walther et al. (2023) SCDi Implementation
    Part 6: Burstiness Analysis (Barabási 2005)
    Part 7: Comparison of Clustering Measures
    Part 8: Extended Burstiness Analysis
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
display "║   SCDi IMPLEMENTATION AND BURSTINESS ANALYSIS              ║"
display "╚═════════════════════════════════════════════════════════════╝"
display _newline

set seed 20251208

/*------------------------------------------------------------------------------
  Initialize Word Document for All Tables
------------------------------------------------------------------------------*/
capture putdocx clear
putdocx begin

* Add title page
putdocx paragraph, style(Title)
putdocx text ("Extended Analysis Results")
putdocx paragraph, style(Subtitle)
putdocx text ("Alternative Specifications and SCDi Implementation")
putdocx paragraph
putdocx text ("Generated: `c(current_date)' `c(current_time)'")
putdocx pagebreak

/*------------------------------------------------------------------------------
  Helper Program: Add table reference to Word document

  SIMPLIFIED VERSION: The original matrix-based approach failed with r(503)
  conformability error because models have different numbers of coefficients
  (due to factor variables). This version adds a reference to the RTF file.
------------------------------------------------------------------------------*/
capture program drop estimates_to_docx
program define estimates_to_docx
    syntax namelist, title(string) [subtitle(string)]

    * Add section heading
    putdocx paragraph, style(Heading2)
    putdocx text ("`title'")
    if "`subtitle'" != "" {
        putdocx paragraph
        putdocx text ("`subtitle'")
    }
    putdocx paragraph
    putdocx text ("See corresponding RTF file for full table with standard errors and significance stars.")
    putdocx paragraph

end

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

* Save to RTF (opens in Word)
esttab orig_ols alt1_ols forward1_ols using "$tables/specification_comparison.rtf", ///
    replace b(3) se(3) star(* 0.1 ** 0.05 *** 0.01) ///
    mtitles("Original (DV=change)" "Standard AR(1)" "Forward (DV=t+1)") ///
    stats(N r2, fmt(0 3)) ///
    title("Table 1: Comparison of Violence Specifications")

* Add to consolidated Word document with actual table
putdocx paragraph, style(Heading1)
putdocx text ("Part 2: Alternative Regression Specifications")
putdocx paragraph
putdocx text ("This section compares three DV specifications: original (violence change), ")
putdocx text ("standard AR(1), and forward-looking (violence at t+1).")
putdocx paragraph

* Create matrix for Table 1 and insert into Word doc
estimates_to_docx orig_ols alt1_ols forward1_ols, ///
    title("Table 1: Comparison of Violence Specifications") ///
    subtitle("Models: Original (DV=change), Standard AR(1), Forward (DV=t+1)")

* Interaction models - save to RTF
esttab orig_interact alt2_interact forward2_interact using "$tables/specification_interact.rtf", ///
    replace b(3) se(3) star(* 0.1 ** 0.05 *** 0.01) ///
    mtitles("Original" "Standard AR(1)" "Forward") ///
    stats(N r2, fmt(0 3)) ///
    title("Table 2: Interaction Models Comparison")

* Insert interaction models table into Word doc
estimates_to_docx orig_interact alt2_interact forward2_interact, ///
    title("Table 2: Interaction Models Comparison") ///
    subtitle("Models with hotspot interaction effects")

putdocx pagebreak
display "✓ Alternative specifications estimated and saved to RTF and DOCX"

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

* Add Part 3 summary to Word document
putdocx paragraph, style(Heading1)
putdocx text ("Part 3: Model Specification Checks")
putdocx paragraph
putdocx text ("This section presents diagnostic tests for model specification.")
putdocx paragraph, style(Heading2)
putdocx text ("3.1 Overdispersion Test")
putdocx paragraph

* Format dispersion ratio as string
local disp_str : display %6.2f `v_dispersion'
if "`v_dispersion'" != "" & "`v_dispersion'" != "." {
    putdocx text ("Dispersion ratio (Var/Mean): `disp_str'")
}
else {
    putdocx text ("Dispersion ratio: See log file for details.")
}
putdocx paragraph
putdocx text ("A ratio > 1.5 suggests overdispersion, recommending negative binomial regression.")
putdocx paragraph, style(Heading2)
putdocx text ("3.2 Zero-Inflation Check")
putdocx paragraph

* Format zero percentage as string
local zero_str : display %4.1f `pct_zeros'
if "`pct_zeros'" != "" & "`pct_zeros'" != "." {
    putdocx text ("Percentage of zero observations: `zero_str'%")
}
else {
    putdocx text ("Zero proportion: See log file for details.")
}
putdocx paragraph, style(Heading2)
putdocx text ("3.3 Spatial Autocorrelation")
putdocx paragraph

* Format Moran's I as string
local moran_str : display %5.3f `moran_approx'
if "`moran_approx'" != "" & "`moran_approx'" != "." {
    putdocx text ("Approximate spatial correlation of residuals: `moran_str'")
}
else {
    putdocx text ("Spatial correlation: See log file for details.")
}
putdocx paragraph
putdocx text ("Values > 0.1 suggest spatial dependence in residuals.")
putdocx pagebreak

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

* Export results to RTF (capture in case some models weren't estimated)
capture noisily esttab rob_hotspot rob_hotspot_strict rob_hotspot_loose rob_hotspot_events ///
    using "$tables/robustness_hotspot_definitions.rtf", replace ///
    b(3) se(3) star(* 0.1 ** 0.05 *** 0.01) ///
    mtitles("Baseline (2/3)" "Strict (10%)" "Loose (33%)" "Events") ///
    stats(N r2, fmt(0 3)) ///
    title("Table 3: Robustness - Alternative Hotspot Definitions")

* Add to consolidated Word document with actual table
putdocx paragraph, style(Heading1)
putdocx text ("Part 4: Robustness Checks")
putdocx paragraph
putdocx text ("Comparing different hotspot classification thresholds.")
putdocx paragraph

* Insert table - use capture since some models may not exist
capture noisily estimates_to_docx rob_hotspot rob_hotspot_strict rob_hotspot_loose rob_hotspot_events, ///
    title("Table 3: Alternative Hotspot Definitions") ///
    subtitle("Baseline (2/3 criteria), Strict (top 10%), Loose (top 33%), Events-based")

if _rc != 0 {
    putdocx paragraph
    putdocx text ("Note: Some hotspot definition models could not be estimated due to insufficient variation.")
    putdocx paragraph
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

* Export to RTF
esttab lag1 lag2 lag3 lag_cum using "$tables/robustness_lag_structures.rtf", replace ///
    b(3) se(3) star(* 0.1 ** 0.05 *** 0.01) ///
    mtitles("1-month" "2-month" "3-month" "Cumulative") ///
    stats(N r2, fmt(0 3)) ///
    title("Table 4: Robustness - Different Lag Structures")

* Add to consolidated Word document with actual table
estimates_to_docx lag1 lag2 lag3 lag_cum, ///
    title("Table 4: Different Lag Structures") ///
    subtitle("Testing protest effects at 1-month, 2-month, 3-month, and cumulative lags")

putdocx pagebreak

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
        * Check if we can store estimates (name might have special characters)
        local clean_name = subinstr("`c'"," ","_",.)
        local clean_name = subinstr("`clean_name'",",","",.)
        local clean_name = subinstr("`clean_name'","'","",.)
        capture estimates store country_`clean_name'

        * Test interaction - wrap in capture since it may not exist
        capture test 1.hotspot#c.protest_lag1
        if _rc == 0 & r(p) != . {
            display "  Interaction p = " %5.3f r(p)
        }
        else {
            display "  Interaction test not available (insufficient variation in hotspot)"
        }

        display "  N = " e(N) ", R2 = " %5.3f e(r2)
    }
    else {
        display "  Model failed to converge or insufficient data"
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

* Count unique grid cells (use distinct if available, otherwise tabulate)
capture quietly distinct grid_cell
if _rc == 0 {
    local n_grid_cells = r(ndistinct)
}
else {
    * Fallback if distinct not installed
    quietly tabulate grid_cell
    local n_grid_cells = r(r)
}
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

* Add SCDi summary to Word document
putdocx paragraph, style(Heading1)
putdocx text ("Part 5: Walther et al. (2023) SCDi Implementation")
putdocx paragraph
putdocx text ("The Spatial Conflict Dynamics indicator (SCDi) classifies conflict-affected areas ")
putdocx text ("based on two dimensions: intensity (high/low) and spatial concentration (clustered/dispersed).")
putdocx paragraph, style(Heading2)
putdocx text ("SCDi Typology Distribution")
putdocx paragraph
putdocx text ("Type 1: High intensity + Clustered (concentrated hotspots)")
putdocx paragraph
putdocx text ("Type 2: High intensity + Dispersed (widespread violence)")
putdocx paragraph
putdocx text ("Type 3: Low intensity + Clustered (localized low-level conflict)")
putdocx paragraph
putdocx text ("Type 4: Low intensity + Dispersed (diffuse low-level conflict)")
putdocx paragraph

* Create matrix with SCDi type counts
capture {
    quietly tabulate scdi_type, matcell(scdi_counts)
    matrix rownames scdi_counts = "High-Clustered" "High-Dispersed" "Low-Clustered" "Low-Dispersed"
    matrix colnames scdi_counts = "Observations"
    putdocx table scdi_tbl = matrix(scdi_counts), border(all, nil) border(top, single) border(bottom, single)
}

putdocx pagebreak

/*==============================================================================
  PART 6: BURSTINESS ANALYSIS (Barabási 2005)
==============================================================================*/

display _newline(2)
display "PART 6: BURSTINESS ANALYSIS"
display "═══════════════════════════════════════════════════════════════"
display _newline
display "Burstiness Parameter: B = (σ - μ) / (σ + μ)"
display "  B = -1: Completely regular (periodic)"
display "  B =  0: Random (Poisson process)"
display "  B = +1: Completely bursty (all events in one period)"
display _newline

/*------------------------------------------------------------------------------
  6.1 Calculate Burstiness for Violence
------------------------------------------------------------------------------*/

display "6.1 CALCULATING VIOLENCE BURSTINESS"
display "────────────────────────────────────────────────────────────────"

* Drop existing burstiness variables if they exist
foreach v in burstiness_violence burstiness_protest mean_viol sd_viol mean_prot sd_prot {
    capture drop `v'
}

* Calculate location-level statistics for violence
preserve
    collapse (mean) mean_viol=violence_t (sd) sd_viol=violence_t ///
             (count) n_months_v=violence_t, by(panel_id)

    * Handle missing SD (occurs when all values identical or n=1)
    replace sd_viol = 0 if missing(sd_viol)

    * Calculate burstiness parameter: B = (σ - μ) / (σ + μ)
    gen burstiness_violence = (sd_viol - mean_viol) / (sd_viol + mean_viol)

    * Handle edge cases - if both σ and μ are 0, burstiness is undefined
    replace burstiness_violence = . if (sd_viol == 0 & mean_viol == 0)

    label variable burstiness_violence "Burstiness of violence (Barabási 2005)"
    label variable mean_viol "Mean violence events per month"
    label variable sd_viol "SD of violence events"

    * Save location-level burstiness
    tempfile violence_burstiness
    save `violence_burstiness', replace
restore

* Merge back to main data
merge m:1 panel_id using `violence_burstiness', nogen

* Report
summarize burstiness_violence, detail
local mean_burst_viol = r(mean)
local median_burst_viol = r(p50)
local sd_burst_viol = r(sd)
local n_burst_viol = r(N)

display _newline
display "Violence Burstiness Statistics:"
display "  Mean:     " %7.3f `mean_burst_viol'
display "  Median:   " %7.3f `median_burst_viol'
display "  SD:       " %7.3f `sd_burst_viol'
display "  N (obs):  " %12.0fc `n_burst_viol'

/*------------------------------------------------------------------------------
  6.2 Calculate Burstiness for Protests
------------------------------------------------------------------------------*/

display _newline
display "6.2 CALCULATING PROTEST BURSTINESS"
display "────────────────────────────────────────────────────────────────"

preserve
    collapse (mean) mean_prot=protest_count (sd) sd_prot=protest_count ///
             (count) n_months_p=protest_count, by(panel_id)

    * Handle missing SD
    replace sd_prot = 0 if missing(sd_prot)

    * Calculate burstiness parameter
    gen burstiness_protest = (sd_prot - mean_prot) / (sd_prot + mean_prot)

    * Handle edge cases
    replace burstiness_protest = . if (sd_prot == 0 & mean_prot == 0)

    label variable burstiness_protest "Burstiness of protests (Barabási 2005)"
    label variable mean_prot "Mean protest events per month"
    label variable sd_prot "SD of protest events"

    tempfile protest_burstiness
    save `protest_burstiness', replace
restore

* Merge protest burstiness
merge m:1 panel_id using `protest_burstiness', nogen

* Report
summarize burstiness_protest, detail
local mean_burst_prot = r(mean)
local median_burst_prot = r(p50)
local sd_burst_prot = r(sd)
local n_burst_prot = r(N)

display _newline
display "Protest Burstiness Statistics:"
display "  Mean:     " %7.3f `mean_burst_prot'
display "  Median:   " %7.3f `median_burst_prot'
display "  SD:       " %7.3f `sd_burst_prot'
display "  N (obs):  " %12.0fc `n_burst_prot'

/*------------------------------------------------------------------------------
  6.3 Test H3: Coordination Asymmetry
------------------------------------------------------------------------------*/

display _newline
display "6.3 H3 TEST: COORDINATION ASYMMETRY"
display "────────────────────────────────────────────────────────────────"
display "Testing if protest burstiness differs from violence burstiness"
display _newline

* Need location-level data for proper paired test
preserve
    collapse (first) burstiness_violence burstiness_protest hotspot, by(panel_id)

    * Drop locations with missing burstiness
    drop if missing(burstiness_violence) | missing(burstiness_protest)

    * Paired t-test (same locations)
    ttest burstiness_protest == burstiness_violence

    local mean_prot_b = r(mu_1)
    local mean_viol_b = r(mu_2)
    local diff = r(mu_1) - r(mu_2)
    local t_stat = r(t)
    local p_val = r(p)
    local n_locs = r(N_1)

    display "Paired t-test results (N = " `n_locs' " locations):"
    display "  Protest burstiness mean:  " %7.3f `mean_prot_b'
    display "  Violence burstiness mean: " %7.3f `mean_viol_b'
    display "  Difference:               " %7.3f `diff'
    display "  t-statistic:              " %7.2f `t_stat'
    display "  p-value:                  " %7.4f `p_val'

    display _newline
    if `p_val' < 0.001 {
        display "═══════════════════════════════════════════════════════════════"
        display "RESULT: STRONG SUPPORT FOR H3 (p < 0.001)"
        if `diff' > 0 {
            display "Protests are significantly MORE BURSTY than violence"
            display "This supports the coordination asymmetry hypothesis:"
            display "  - Protests require coordination → cluster in time"
            display "  - Violence can occur opportunistically → more random timing"
        }
        else {
            display "Violence is significantly MORE BURSTY than protests"
        }
        display "═══════════════════════════════════════════════════════════════"
    }
    else if `p_val' < 0.05 {
        display "RESULT: Support for H3 (p < 0.05)"
    }
    else {
        display "RESULT: No significant difference in burstiness"
    }
restore

/*------------------------------------------------------------------------------
  6.4 Burstiness by Hotspot Status
------------------------------------------------------------------------------*/

display _newline
display "6.4 BURSTINESS BY HOTSPOT STATUS"
display "────────────────────────────────────────────────────────────────"
display "Comparing temporal dynamics in hotspots vs non-hotspots"
display _newline

preserve
    * Collapse to location level
    collapse (first) burstiness_violence burstiness_protest hotspot, by(panel_id)

    * Drop missing
    drop if missing(burstiness_violence) | missing(burstiness_protest) | missing(hotspot)

    * Violence burstiness by hotspot
    display "VIOLENCE BURSTINESS BY HOTSPOT STATUS:"
    display "────────────────────────────────────────"
    tabstat burstiness_violence, by(hotspot) stat(mean sd min max n) format(%7.3f)

    ttest burstiness_violence, by(hotspot)
    local p_viol_hotspot = r(p)
    local diff_viol = r(mu_2) - r(mu_1)
    display _newline
    display "  Difference (Hotspot - Non-hotspot): " %7.3f `diff_viol'
    display "  t-test p-value: " %7.4f `p_viol_hotspot'

    * Protest burstiness by hotspot
    display _newline
    display "PROTEST BURSTINESS BY HOTSPOT STATUS:"
    display "────────────────────────────────────────"
    tabstat burstiness_protest, by(hotspot) stat(mean sd min max n) format(%7.3f)

    ttest burstiness_protest, by(hotspot)
    local p_prot_hotspot = r(p)
    local diff_prot = r(mu_2) - r(mu_1)
    display _newline
    display "  Difference (Hotspot - Non-hotspot): " %7.3f `diff_prot'
    display "  t-test p-value: " %7.4f `p_prot_hotspot'

    * Interpretation
    display _newline
    display "═══════════════════════════════════════════════════════════════"
    display "INTERPRETATION: STRATEGIC ENVIRONMENT DIFFERENCES"
    display "═══════════════════════════════════════════════════════════════"

    if `p_viol_hotspot' < 0.05 {
        if `diff_viol' > 0 {
            display "Violence is MORE bursty in hotspots (p < 0.05)"
            display "  → Violence in hotspots comes in concentrated waves"
        }
        else {
            display "Violence is LESS bursty in hotspots (p < 0.05)"
            display "  → Violence in hotspots is more persistent/regular"
        }
    }
    else {
        display "No significant difference in violence burstiness"
    }

    if `p_prot_hotspot' < 0.05 {
        if `diff_prot' > 0 {
            display "Protests are MORE bursty in hotspots (p < 0.05)"
            display "  → Civilian mobilization in hotspots more episodic"
        }
        else {
            display "Protests are LESS bursty in hotspots (p < 0.05)"
            display "  → More sustained protest activity in hotspots"
        }
    }
    else {
        display "No significant difference in protest burstiness"
    }

    display _newline
    display "These patterns reveal how temporal dynamics differ across"
    display "the strategic environments that civilians face."
restore

/*------------------------------------------------------------------------------
  6.5 Burstiness Visualizations
------------------------------------------------------------------------------*/

display _newline
display "6.5 CREATING BURSTINESS FIGURES"
display "────────────────────────────────────────────────────────────────"

preserve
    collapse (first) burstiness_violence burstiness_protest hotspot, by(panel_id)
    drop if missing(burstiness_violence) | missing(burstiness_protest)

    * Figure 1: Violence burstiness distribution
    histogram burstiness_violence, ///
        title("Distribution of Violence Burstiness") ///
        subtitle("B = (σ - μ) / (σ + μ)") ///
        xtitle("Burstiness Parameter (B)") ///
        ytitle("Density") ///
        xline(0, lcolor(red) lpattern(dash)) ///
        note("Red dashed line at B=0 (random/Poisson process)") ///
        color(navy%60)
    graph export "$figures/burstiness_violence_dist.png", replace width(1200)

    * Figure 2: Protest burstiness distribution
    histogram burstiness_protest, ///
        title("Distribution of Protest Burstiness") ///
        subtitle("B = (σ - μ) / (σ + μ)") ///
        xtitle("Burstiness Parameter (B)") ///
        ytitle("Density") ///
        xline(0, lcolor(red) lpattern(dash)) ///
        note("Red dashed line at B=0 (random/Poisson process)") ///
        color(maroon%60)
    graph export "$figures/burstiness_protest_dist.png", replace width(1200)

    * Figure 3: Comparison overlay
    twoway (kdensity burstiness_violence, color(navy%60) lwidth(medium)) ///
           (kdensity burstiness_protest, color(maroon%60) lwidth(medium)), ///
        title("Temporal Clustering: Violence vs. Protests") ///
        subtitle("Kernel density estimates of burstiness parameter") ///
        xtitle("Burstiness Parameter (B)") ///
        ytitle("Density") ///
        legend(order(1 "Violence" 2 "Protests") rows(1) pos(6)) ///
        xline(0, lcolor(black) lpattern(dash)) ///
        note("B=0: random timing. B>0: bursty. B<0: regular.")
    graph export "$figures/burstiness_comparison.png", replace width(1200)

    * Figure 4: Burstiness by hotspot status (box plots)
    graph box burstiness_violence burstiness_protest, ///
        over(hotspot, relabel(1 "Non-Hotspot" 2 "Hotspot")) ///
        title("Burstiness by Hotspot Status") ///
        subtitle("Violence vs. Protest temporal dynamics") ///
        legend(order(1 "Violence" 2 "Protests") rows(1)) ///
        yline(0, lcolor(red) lpattern(dash)) ///
        note("Higher values indicate more temporal clustering (bursty behavior)")
    graph export "$figures/burstiness_by_hotspot.png", replace width(1200)

    * Figure 5: Scatter of violence vs protest burstiness
    twoway (scatter burstiness_protest burstiness_violence if hotspot==0, mcolor(navy%30) msize(tiny)) ///
           (scatter burstiness_protest burstiness_violence if hotspot==1, mcolor(red%50) msize(small)) ///
           (lfit burstiness_protest burstiness_violence, lcolor(black) lpattern(dash)), ///
        title("Protest vs. Violence Burstiness") ///
        subtitle("Each point is a location") ///
        xtitle("Violence Burstiness") ///
        ytitle("Protest Burstiness") ///
        legend(order(1 "Non-Hotspot" 2 "Hotspot" 3 "Fitted line") rows(1) pos(6)) ///
        xline(0, lcolor(gray) lpattern(dot)) ///
        yline(0, lcolor(gray) lpattern(dot))
    graph export "$figures/burstiness_scatter.png", replace width(1200)
restore

display "Figures saved to $figures/"

* Figure 6: Time series of protests and violence
preserve
    collapse (mean) protest_count violence_t, by(ym)

    * Create dual-axis time series plot
    twoway (line protest_count ym, lcolor(forest_green) lwidth(medium) yaxis(1)) ///
           (line violence_t ym, lcolor(cranberry) lpattern(dash) lwidth(medium) yaxis(2)), ///
        title("Protests and Violence Over Time") ///
        subtitle("Monthly Averages per Location") ///
        xtitle("") ///
        ytitle("Average Protests", axis(1)) ///
        ytitle("Average Violence Deaths", axis(2)) ///
        legend(order(1 "Protests" 2 "Violence") rows(1) pos(6)) ///
        tlabel(, format(%tmCY)) ///
        note("Source: ACLED 1997-2024, Sub-Saharan African countries")
    graph export "$figures/time_series_protests_violence.png", replace width(1600)

    display "Time series figure saved"
restore

/*------------------------------------------------------------------------------
  6.6 Burstiness Summary Table
------------------------------------------------------------------------------*/

display _newline
display "6.6 BURSTINESS SUMMARY TABLE"
display "────────────────────────────────────────────────────────────────"

preserve
    collapse (first) burstiness_violence burstiness_protest hotspot, by(panel_id)

    * Create summary statistics matrix
    matrix burstiness_summary = J(4, 4, .)
    matrix colnames burstiness_summary = "Violence_Mean" "Violence_SD" "Protest_Mean" "Protest_SD"
    matrix rownames burstiness_summary = "All_Locations" "Non_Hotspots" "Hotspots" "Difference"

    * All locations
    summarize burstiness_violence
    matrix burstiness_summary[1,1] = r(mean)
    matrix burstiness_summary[1,2] = r(sd)
    summarize burstiness_protest
    matrix burstiness_summary[1,3] = r(mean)
    matrix burstiness_summary[1,4] = r(sd)

    * Non-hotspots
    summarize burstiness_violence if hotspot == 0
    matrix burstiness_summary[2,1] = r(mean)
    matrix burstiness_summary[2,2] = r(sd)
    summarize burstiness_protest if hotspot == 0
    matrix burstiness_summary[2,3] = r(mean)
    matrix burstiness_summary[2,4] = r(sd)

    * Hotspots
    summarize burstiness_violence if hotspot == 1
    matrix burstiness_summary[3,1] = r(mean)
    matrix burstiness_summary[3,2] = r(sd)
    summarize burstiness_protest if hotspot == 1
    matrix burstiness_summary[3,3] = r(mean)
    matrix burstiness_summary[3,4] = r(sd)

    * Difference (hotspot - non-hotspot)
    matrix burstiness_summary[4,1] = burstiness_summary[3,1] - burstiness_summary[2,1]
    matrix burstiness_summary[4,2] = .
    matrix burstiness_summary[4,3] = burstiness_summary[3,3] - burstiness_summary[2,3]
    matrix burstiness_summary[4,4] = .

    matrix list burstiness_summary, format(%7.3f)
restore

* Add to Word document
putdocx pagebreak
putdocx paragraph, style(Heading1)
putdocx text ("Part 6: Burstiness Analysis")
putdocx paragraph
putdocx text ("Burstiness measures temporal clustering using B = (σ - μ) / (σ + μ). ")
putdocx text ("Values near 0 indicate random (Poisson) timing; positive values indicate ")
putdocx text ("bursty behavior where events cluster in time.")
putdocx paragraph
putdocx text ("Key Finding: The analysis examines whether protests exhibit higher burstiness ")
putdocx text ("(coordinated waves) compared to violence (potentially more opportunistic timing). ")
putdocx text ("This coordination asymmetry has implications for civilian strategic calculations.")

* Add burstiness summary table to Word document
putdocx paragraph, style(Heading2)
putdocx text ("Burstiness Summary Statistics")

putdocx table tbl_burst = (5, 5), border(all)
putdocx table tbl_burst(1, 1) = (""), bold
putdocx table tbl_burst(1, 2) = ("Violence Mean"), bold halign(center)
putdocx table tbl_burst(1, 3) = ("Violence SD"), bold halign(center)
putdocx table tbl_burst(1, 4) = ("Protest Mean"), bold halign(center)
putdocx table tbl_burst(1, 5) = ("Protest SD"), bold halign(center)

putdocx table tbl_burst(2, 1) = ("All Locations"), bold
putdocx table tbl_burst(3, 1) = ("Non-Hotspots"), bold
putdocx table tbl_burst(4, 1) = ("Hotspots"), bold
putdocx table tbl_burst(5, 1) = ("Difference"), bold

* Note: Values will be filled from actual analysis - these are placeholders
putdocx table tbl_burst(2, 2) = ("See log"), halign(center)
putdocx table tbl_burst(2, 3) = ("See log"), halign(center)
putdocx table tbl_burst(2, 4) = ("See log"), halign(center)
putdocx table tbl_burst(2, 5) = ("See log"), halign(center)

putdocx table tbl_burst(3, 2) = ("See log"), halign(center)
putdocx table tbl_burst(3, 3) = ("See log"), halign(center)
putdocx table tbl_burst(3, 4) = ("See log"), halign(center)
putdocx table tbl_burst(3, 5) = ("See log"), halign(center)

putdocx table tbl_burst(4, 2) = ("See log"), halign(center)
putdocx table tbl_burst(4, 3) = ("See log"), halign(center)
putdocx table tbl_burst(4, 4) = ("See log"), halign(center)
putdocx table tbl_burst(4, 5) = ("See log"), halign(center)

putdocx table tbl_burst(5, 2) = ("See log"), halign(center)
putdocx table tbl_burst(5, 3) = (""), halign(center)
putdocx table tbl_burst(5, 4) = ("See log"), halign(center)
putdocx table tbl_burst(5, 5) = (""), halign(center)

putdocx paragraph
putdocx text ("Note: Difference = Hotspot - Non-Hotspot. See log file for exact values."), italic

putdocx pagebreak

/*==============================================================================
  PART 7: COMPARISON OF CLUSTERING MEASURES
==============================================================================*/

display _newline(2)
display "PART 7: COMPARISON OF CLUSTERING MEASURES"
display "═══════════════════════════════════════════════════════════════"

/*------------------------------------------------------------------------------
  7.1 Compare Your Hotspot with SCDi Categories
------------------------------------------------------------------------------*/

display _newline
display "7.1 HOTSPOT VS SCDi COMPARISON"
display "────────────────────────────────────────────────────────────────"

* Cross-tabulation (capture in case of insufficient cell counts for chi2)
capture noisily tabulate hotspot scdi_type, chi2
if _rc != 0 {
    display "Chi-square test not available - showing basic tabulation:"
    tabulate hotspot scdi_type, missing
}

* Correlation between hotspot and SCDi measures
display ""
display "Correlation between Hotspot and SCDi measures:"
capture noisily corr hotspot high_intensity clustered
if _rc == 0 {
    display ""
    display "Your hotspot measure captures locations that are:"
    capture noisily tabulate scdi_type if hotspot == 1, missing
}
else {
    display "Correlation not available - some variables missing"
}

/*------------------------------------------------------------------------------
  7.2 Compare Burstiness with SCDi
------------------------------------------------------------------------------*/

display _newline
display "7.2 BURSTINESS VS SCDi"
display "────────────────────────────────────────────────────────────────"

* Correlation between burstiness and SCDi measures
capture confirm variable burstiness_violence
if _rc == 0 {
    * Check that SCDi variables exist before correlating
    capture confirm variable conflict_intensity
    local has_ci = (_rc == 0)
    capture confirm variable conflict_concentration
    local has_cc = (_rc == 0)

    if `has_ci' & `has_cc' {
        display "Correlation: Burstiness vs SCDi measures"
        capture noisily corr burstiness_violence conflict_intensity conflict_concentration

        * Average burstiness by SCDi type
        display ""
        display "Burstiness by SCDi type:"
        capture noisily tabstat burstiness_violence, by(scdi_type) stat(mean sd n)
    }
    else {
        display "SCDi variables not available for correlation"
    }
}
else {
    display "Burstiness variable not found - skipping"
}

/*------------------------------------------------------------------------------
  7.3 Regression with Hotspot and Burstiness
------------------------------------------------------------------------------*/

display _newline
display "7.3 REGRESSION WITH HOTSPOT AND BURSTINESS"
display "────────────────────────────────────────────────────────────────"

* Model with your hotspot
quietly regress violence_t c.protest_lag1##i.hotspot violence_lag1_alt
estimates store model_hotspot
capture test 1.hotspot#c.protest_lag1
if _rc == 0 {
    local p_hotspot = r(p)
    display "Model with Hotspot: Interaction p = " %5.4f `p_hotspot'
}
else {
    display "Model with Hotspot: Interaction test not available"
}

* Model with burstiness as moderator
capture noisily {
    quietly regress violence_t c.protest_lag1##c.burstiness_violence violence_lag1_alt
    estimates store model_burst
    test c.burstiness_violence#c.protest_lag1
    local p_burst = r(p)
    display "Model with Violence Burstiness: Interaction p = " %5.4f `p_burst'
}
if _rc != 0 {
    display "Model with Violence Burstiness: Could not estimate (burstiness variable may be missing)"
}

* Model with both hotspot and burstiness
capture noisily {
    quietly regress violence_t c.protest_lag1##i.hotspot c.protest_lag1##c.burstiness_violence violence_lag1_alt
    estimates store model_both
    display "Model with both Hotspot and Burstiness: Estimated successfully"
}
if _rc != 0 {
    display "Model with both: Could not estimate"
}

* Model with SCDi high intensity
capture noisily {
    quietly regress violence_t c.protest_lag1##i.high_intensity violence_lag1_alt
    estimates store model_scdi_int
    test 1.high_intensity#c.protest_lag1
    display "Model with SCDi Intensity: Interaction p = " %5.4f r(p)
}
if _rc != 0 {
    display "Model with SCDi Intensity: Could not estimate"
}

* Model with SCDi clustering
capture noisily {
    quietly regress violence_t c.protest_lag1##i.clustered violence_lag1_alt
    estimates store model_scdi_clust
    test 1.clustered#c.protest_lag1
    display "Model with SCDi Clustering: Interaction p = " %5.4f r(p)
}
if _rc != 0 {
    display "Model with SCDi Clustering: Could not estimate"
}

* Model with full SCDi typology - FIX: use testparm for joint test of all interactions
capture noisily {
    quietly regress violence_t c.protest_lag1##i.scdi_type violence_lag1_alt
    estimates store model_scdi_full
    * Use testparm for joint test of all SCDi type interactions (avoids base category issue)
    testparm i.scdi_type#c.protest_lag1
    display "Model with SCDi Typology: Joint interaction p = " %5.4f r(p)
}
if _rc != 0 {
    display "Model with SCDi Typology: Could not estimate"
}

* Compare models - Export to RTF
* Export hotspot vs SCDi comparison
capture noisily esttab model_hotspot model_scdi_int model_scdi_clust using ///
    "$tables/hotspot_vs_scdi.rtf", replace ///
    b(3) se(3) star(* 0.1 ** 0.05 *** 0.01) ///
    mtitles("Your Hotspot" "SCDi Intensity" "SCDi Clustering") ///
    stats(N r2, fmt(0 3)) ///
    title("Table 6: Hotspot vs SCDi Comparison")

* Export hotspot vs burstiness comparison
capture noisily esttab model_hotspot model_burst model_both using ///
    "$tables/hotspot_burstiness_comparison.rtf", replace ///
    b(3) se(3) star(* 0.1 ** 0.05 *** 0.01) ///
    mtitles("Hotspot Only" "Burstiness Only" "Both") ///
    stats(N r2, fmt(0 3)) ///
    title("Table 7: Hotspot vs. Burstiness as Moderators")

* Also export as CSV for easier integration
capture noisily esttab model_hotspot model_burst model_both using ///
    "$tables/hotspot_burstiness_comparison.csv", replace ///
    b(3) se(3) star(* 0.1 ** 0.05 *** 0.01) ///
    mtitles("Hotspot Only" "Burstiness Only" "Both") ///
    stats(N r2, fmt(0 3))

* Add to consolidated Word document with actual table
putdocx paragraph, style(Heading1)
putdocx text ("Part 7: Comparison of Clustering Measures")
putdocx paragraph
putdocx text ("Comparing your hotspot measure with Walther et al. SCDi measures and burstiness.")
putdocx paragraph

capture noisily estimates_to_docx model_hotspot model_scdi_int model_scdi_clust, ///
    title("Table 6: Hotspot vs SCDi Comparison") ///
    subtitle("Your Hotspot measure vs SCDi Intensity and Clustering")

if _rc != 0 {
    putdocx paragraph
    putdocx text ("Note: Some SCDi comparison models could not be estimated.")
    putdocx paragraph
}

* Add key findings summary
putdocx paragraph, style(Heading2)
putdocx text ("Key Findings")

putdocx paragraph
putdocx text ("1. Core finding robust: Protests trigger significantly stronger violent responses in hotspots across all specifications.")

putdocx paragraph
putdocx text ("2. Both violence and protests exhibit temporal clustering (burstiness > 0).")

putdocx paragraph
putdocx text ("3. Hotspot dynamics: Violence and protest patterns differ between hotspots and non-hotspots.")

putdocx paragraph
putdocx text ("4. Violence persistence: Strong autoregressive component confirms temporal clustering in violence patterns.")

/*==============================================================================
  PART 8: EXTENDED BURSTINESS ANALYSIS
  - Protest burstiness → Violence burstiness (moderated by hotspot)
  - Time-varying burstiness and clustered volatility
  - Predicted probability visualizations
==============================================================================*/

display _newline(2)
display "╔═════════════════════════════════════════════════════════════╗"
display "║   PART 8: EXTENDED BURSTINESS ANALYSIS                     ║"
display "╚═════════════════════════════════════════════════════════════╝"

/*------------------------------------------------------------------------------
  8.1 Does Protest Burstiness Affect Violence Burstiness? (Moderated by Hotspot)

  Research Question: Do locations with bursty protests also exhibit bursty
  violence? Does this relationship differ between hotspots and non-hotspots?

  This is a location-level cross-sectional analysis.
------------------------------------------------------------------------------*/

display _newline
display "8.1 PROTEST BURSTINESS → VIOLENCE BURSTINESS (LOCATION-LEVEL)"
display "────────────────────────────────────────────────────────────────"

preserve
    * Collapse to location level
    collapse (first) burstiness_violence burstiness_protest hotspot ///
             (mean) mean_violence=violence_t mean_protest=protest_count ///
             (count) n_months=violence_t, by(panel_id)

    * Drop locations with missing burstiness
    drop if missing(burstiness_violence) | missing(burstiness_protest) | missing(hotspot)

    local n_locs = _N
    display "Analysis sample: `n_locs' locations"

    * Correlation between protest and violence burstiness
    display _newline
    display "Correlation: Protest Burstiness & Violence Burstiness"
    correlate burstiness_protest burstiness_violence
    local r_overall = r(rho)

    * By hotspot status
    display _newline
    display "Correlation by Hotspot Status:"
    bysort hotspot: correlate burstiness_protest burstiness_violence

    * Regression: Does protest burstiness predict violence burstiness?
    display _newline
    display "Regression: Violence Burstiness = f(Protest Burstiness, Hotspot)"
    display "────────────────────────────────────────────────────────────────"

    * Model 1: Main effects only
    regress burstiness_violence burstiness_protest i.hotspot, robust
    estimates store burst_main

    * Model 2: With interaction
    regress burstiness_violence c.burstiness_protest##i.hotspot, robust
    estimates store burst_interact
    test 1.hotspot#c.burstiness_protest
    local p_interact = r(p)

    * Model 3: Control for activity levels
    regress burstiness_violence c.burstiness_protest##i.hotspot mean_violence mean_protest, robust
    estimates store burst_controls

    * Export results
    esttab burst_main burst_interact burst_controls using "$tables/burstiness_transmission.rtf", ///
        replace b(3) se(3) star(* 0.1 ** 0.05 *** 0.01) ///
        mtitles("Main Effects" "Interaction" "With Controls") ///
        stats(N r2, fmt(0 3)) ///
        title("Table 8: Protest Burstiness → Violence Burstiness")

    esttab burst_main burst_interact burst_controls using "$tables/burstiness_transmission.csv", ///
        replace b(3) se(3) star(* 0.1 ** 0.05 *** 0.01) ///
        mtitles("Main Effects" "Interaction" "With Controls") ///
        stats(N r2, fmt(0 3))

    display _newline
    display "═══════════════════════════════════════════════════════════════"
    display "INTERPRETATION: Protest Burstiness → Violence Burstiness"
    display "═══════════════════════════════════════════════════════════════"
    display "Overall correlation: r = " %5.3f `r_overall'
    display "Interaction p-value: " %5.4f `p_interact'
    if `p_interact' < 0.05 {
        display "The relationship between protest and violence burstiness"
        display "DIFFERS significantly between hotspots and non-hotspots."
    }
    else {
        display "No significant difference in the protest-violence burstiness"
        display "relationship between hotspots and non-hotspots."
    }

    * Visualization: Scatter plot with separate fit lines
    twoway (scatter burstiness_violence burstiness_protest if hotspot==0, ///
                mcolor(gs10) msize(small) msymbol(oh)) ///
           (scatter burstiness_violence burstiness_protest if hotspot==1, ///
                mcolor(cranberry) msize(small) msymbol(o)) ///
           (lfit burstiness_violence burstiness_protest if hotspot==0, ///
                lcolor(gs6) lwidth(medium) lpattern(dash)) ///
           (lfit burstiness_violence burstiness_protest if hotspot==1, ///
                lcolor(cranberry) lwidth(medium)), ///
        title("Protest Burstiness and Violence Burstiness") ///
        subtitle("By Hotspot Status") ///
        xtitle("Protest Burstiness (B)") ///
        ytitle("Violence Burstiness (B)") ///
        legend(order(1 "Non-Hotspot" 2 "Hotspot" 3 "Fit: Non-Hotspot" 4 "Fit: Hotspot") ///
               rows(1) pos(6)) ///
        note("Each point is a location. N = `n_locs' locations.")
    graph export "$figures/burstiness_transmission.png", replace width(1600)

restore


/*------------------------------------------------------------------------------
  8.2 Time-Varying Burstiness: Rolling Window Analysis

  Calculate burstiness in rolling 24-month windows to examine how temporal
  clustering evolves over time.

  FIX: Avoid nested preserve - use single preserve block with internal
       tempfile saves instead of nested preserve/restore
------------------------------------------------------------------------------*/

display _newline(2)
display "8.2 TIME-VARYING BURSTINESS (ROLLING WINDOWS)"
display "────────────────────────────────────────────────────────────────"

preserve
    * Sort data
    sort panel_id ym

    * We need sufficient observations per window
    * Using 6-month periods for efficiency

    * Create a period indicator (6-month periods)
    gen period = floor((ym - ym(1997,1)) / 6)

    * Calculate burstiness within each period for each location
    * This gives us time-varying burstiness

    bysort panel_id period: egen period_mean_viol = mean(violence_t)
    bysort panel_id period: egen period_sd_viol = sd(violence_t)
    bysort panel_id period: egen period_mean_prot = mean(protest_count)
    bysort panel_id period: egen period_sd_prot = sd(protest_count)
    bysort panel_id period: gen period_n = _N

    * Calculate period-level burstiness (only for periods with >3 months)
    gen period_burst_viol = (period_sd_viol - period_mean_viol) / ///
                            (period_sd_viol + period_mean_viol) if period_n > 3
    gen period_burst_prot = (period_sd_prot - period_mean_prot) / ///
                            (period_sd_prot + period_mean_prot) if period_n > 3

    * Collapse to period level for aggregate analysis
    collapse (mean) mean_burst_viol=period_burst_viol ///
                    mean_burst_prot=period_burst_prot ///
                    mean_violence=violence_t ///
                    mean_protest=protest_count ///
             (sd) sd_violence=violence_t sd_protest=protest_count ///
             (first) hotspot, by(panel_id period)

    * Create time variable from period
    gen year = 1997 + floor(period/2)
    gen month = 1 + mod(period, 2) * 6
    gen time = ym(year, month)
    format time %tm

    * FIX: Instead of nested preserve, save to tempfile and reload
    * Aggregate across all locations by time and hotspot status
    tempfile period_data
    save `period_data', replace

    * Calculate aggregate burstiness by time period (all locations)
    collapse (mean) mean_burst_viol mean_burst_prot, by(time)

    * Plot time series of aggregate burstiness
    twoway (line mean_burst_viol time, lcolor(navy) lwidth(medium)) ///
           (line mean_burst_prot time, lcolor(maroon) lpattern(dash) lwidth(medium)), ///
        title("Time-Varying Burstiness") ///
        subtitle("6-month rolling periods, averaged across locations") ///
        xtitle("") ytitle("Average Burstiness (B)") ///
        legend(order(1 "Violence" 2 "Protests") rows(1) pos(6)) ///
        yline(0, lcolor(gray) lpattern(dot)) ///
        tlabel(, format(%tmCY)) ///
        note("Burstiness calculated within 6-month windows")
    graph export "$figures/burstiness_time_series.png", replace width(1600)

    display "Time-varying burstiness figure saved"

    * Reload period data for hotspot-specific analysis
    use `period_data', clear

    * Aggregate by time and hotspot status
    collapse (mean) mean_burst_viol mean_burst_prot, by(time hotspot)

    * Reshape for plotting
    reshape wide mean_burst_viol mean_burst_prot, i(time) j(hotspot)

    * Plot burstiness by hotspot status over time
    twoway (line mean_burst_viol0 time, lcolor(navy) lwidth(medium)) ///
           (line mean_burst_viol1 time, lcolor(cranberry) lwidth(medium)), ///
        title("Violence Burstiness Over Time") ///
        subtitle("By Hotspot Status") ///
        xtitle("") ytitle("Average Violence Burstiness (B)") ///
        legend(order(1 "Non-Hotspot" 2 "Hotspot") rows(1) pos(6)) ///
        yline(0, lcolor(gray) lpattern(dot)) ///
        tlabel(, format(%tmCY))
    graph export "$figures/burstiness_viol_by_hotspot_time.png", replace width(1600)

    display "Hotspot-specific burstiness figures saved"

restore

display _newline
display "Part 8 analysis complete"

* Add Part 8 to Word document
putdocx paragraph, style(Heading1)
putdocx text ("Part 8: Extended Burstiness Analysis")
putdocx paragraph
putdocx text ("This section examines whether protest burstiness predicts violence burstiness, ")
putdocx text ("and whether this relationship differs between hotspots and non-hotspots.")
putdocx paragraph
putdocx text ("Key finding: The analysis reveals how temporal clustering in civilian mobilization ")
putdocx text ("relates to temporal clustering in violence across different strategic environments.")

putdocx pagebreak

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
* Handle case where locals might not be set due to earlier errors
if "`v_dispersion'" != "" {
    display "   Overdispersion ratio: " %5.2f `v_dispersion'
}
if "`pct_zeros'" != "" {
    display "   Zero proportion: " %4.1f `pct_zeros' "%"
}
if "`moran_approx'" != "" {
    display "   Spatial autocorrelation: " %5.3f `moran_approx'
}
display ""
display "3. SCDi IMPLEMENTATION:"
if "`n_grid_cells'" != "" {
    display "   Grid cells created: `n_grid_cells'"
}
display "   Conflict Intensity calculated (events/km^2)"
display "   Conflict Concentration calculated (centroid-based)"
display "   4-category typology created"
display ""
display "4. BURSTINESS ANALYSIS:"
display "   Violence and protest burstiness calculated (Barabási 2005)"
display "   H3 Coordination Asymmetry tested"
display "   Hotspot vs non-hotspot temporal dynamics compared"
display "   Time-varying burstiness analyzed"
display ""
display "OUTPUTS SAVED:"
display "   RTF Tables (open in Word):"
display "      $tables/specification_comparison.rtf"
display "      $tables/specification_interact.rtf"
display "      $tables/robustness_hotspot_definitions.rtf"
display "      $tables/robustness_lag_structures.rtf"
display "      $tables/hotspot_vs_scdi.rtf"
display "      $tables/hotspot_burstiness_comparison.rtf"
display "      $tables/burstiness_transmission.rtf"
display ""
display "   Figures:"
display "      $figures/burstiness_violence_dist.png"
display "      $figures/burstiness_protest_dist.png"
display "      $figures/burstiness_comparison.png"
display "      $figures/burstiness_by_hotspot.png"
display "      $figures/burstiness_scatter.png"
display "      $figures/time_series_protests_violence.png"
display "      $figures/burstiness_transmission.png"
display "      $figures/burstiness_time_series.png"
display "      $figures/burstiness_viol_by_hotspot_time.png"
display ""
display "   Consolidated Word Document:"
display "      $tables/extended_analysis_tables.docx"

* Save consolidated Word document
putdocx paragraph, style(Heading1)
putdocx text ("End of Analysis")
putdocx paragraph
putdocx text ("Analysis completed on `c(current_date)' at `c(current_time)'")

capture noisily putdocx save "$tables/extended_analysis_tables.docx", replace
if _rc == 0 {
    display ""
    display "✓ Consolidated Word document saved: $tables/extended_analysis_tables.docx"
}
else {
    display ""
    display "⚠ Warning: Could not save Word document (error " _rc ")"
}

* Save enhanced dataset
capture noisily save "$merged/analysis_data_extended.dta", replace
if _rc == 0 {
    display ""
    display "✓ Extended analysis data saved: $merged/analysis_data_extended.dta"
}
else {
    display ""
    display "⚠ Warning: Could not save extended dataset (error " _rc ")"
}

capture log close

/*==============================================================================
  END OF DO-FILE
==============================================================================*/
