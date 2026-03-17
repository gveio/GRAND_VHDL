vsim -gui work.ORBGRAND_tb

# ============================================================
# CLOCK & RESET
# ============================================================
add wave -divider "Clock & Reset"
add wave sim:/ORBGRAND_tb/clk
add wave sim:/ORBGRAND_tb/rst

# ============================================================
# FSM STATE
# ============================================================
add wave -divider "State"
add wave sim:/orbgrand_tb/DUT/fsm/state

# ============================================================
# TOP-LEVEL INPUTS
# ============================================================
add wave -divider "Top Inputs"
add wave sim:/ORBGRAND_tb/dec_en
add wave sim:/ORBGRAND_tb/H_matrix_id
add wave sim:/ORBGRAND_tb/LLR_in

# ============================================================
# LLR EXTRACTION (MAG + HARD DECISION)
# ============================================================
add wave -divider "Hard Decision & Magnitudes"
add wave sim:/ORBGRAND_tb/DUT/LLR_mag_sig
add wave sim:/ORBGRAND_tb/DUT/y_hard_sig
add wave sim:/ORBGRAND_tb/DUT/llr_done_sig

# ============================================================
# DECODER SELECTOR / MUX
# ============================================================
add wave -divider "HD / Guess Selector"
add wave sim:/ORBGRAND_tb/DUT/y_sel_sig
add wave sim:/ORBGRAND_tb/DUT/y_check
add wave sim:/ORBGRAND_tb/DUT/y_check_reg

# ============================================================
# MEMBERSHIP CHECKER
# ============================================================
add wave -divider "Membership Checker"
add wave sim:/ORBGRAND_tb/DUT/start_memb_check_sig
add wave sim:/ORBGRAND_tb/DUT/syndrome_sig
add wave sim:/ORBGRAND_tb/DUT/memb_done_sig
add wave sim:/ORBGRAND_tb/DUT/valid_sig
add wave sim:/ORBGRAND_tb/DUT/found_valid

# ============================================================
# DECODER FINAL OUTPUT
# ============================================================
add wave -divider "Decoder Output"
add wave sim:/ORBGRAND_tb/dec_done
add wave sim:/ORBGRAND_tb/y_decoded

# ============================================================
# SORTER
# ============================================================
add wave -divider "Sorter"
add wave sim:/ORBGRAND_tb/DUT/sort_en_sig
add wave sim:/ORBGRAND_tb/DUT/sorted_indices_sig
add wave sim:/ORBGRAND_tb/DUT/done_sort_sig

# ============================================================
# PATTERN GENERATOR
# ============================================================
add wave -divider "Pattern Generator"
add wave sim:/ORBGRAND_tb/DUT/pattern_en_sig
add wave sim:/ORBGRAND_tb/DUT/LW_sig
add wave sim:/ORBGRAND_tb/DUT/HW_sig
add wave sim:/ORBGRAND_tb/DUT/abandon_sig
add wave sim:/ORBGRAND_tb/DUT/pattern_sig
add wave sim:/ORBGRAND_tb/DUT/per_pattern_done_sig
add wave sim:/ORBGRAND_tb/DUT/pattern_done_sig

# ============================================================
# ERROR GENERATOR (NOISE + GUESSED SEQUENCE)
# ============================================================
add wave -divider "Error Generator"
add wave sim:/ORBGRAND_tb/DUT/error_done_sig
add wave sim:/ORBGRAND_tb/DUT/noise_vec_sig
add wave sim:/ORBGRAND_tb/DUT/y_guessed_sig

