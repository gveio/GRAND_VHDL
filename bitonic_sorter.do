vsim -gui work.bitonic_sorter_tb

# ============================================================
# Clock & Reset
# ============================================================
add wave -divider "Clock & Reset"
add wave sim:/bitonic_sorter_tb/clk
add wave sim:/bitonic_sorter_tb/rst

# ============================================================
# Inputs
# ============================================================
add wave -divider "Inputs"
add wave sim:/bitonic_sorter_tb/LLR_mag
add wave sim:/bitonic_sorter_tb/DUT/sort_en

# ============================================================
# Runtime parameters
# ============================================================
add wave -divider "Runtime parameters"
add wave sim:/bitonic_sorter_tb/DUT/n_r
add wave sim:/bitonic_sorter_tb/DUT/config_done
add wave sim:/bitonic_sorter_tb/DUT/load_en

# ============================================================
# Magnitude & Index Pipeline Registers
# ============================================================
add wave -divider "Mag,Index regs"
add wave sim:/bitonic_sorter_tb/DUT/mag_stages
add wave sim:/bitonic_sorter_tb/DUT/idx_stages

# ============================================================
# Valid Pipeline Control
# ============================================================
add wave -divider "Valid Pipeline Control"
add wave sim:/bitonic_sorter_tb/DUT/stage_valid

# ============================================================
# Outputs
# ============================================================
add wave -divider "Outputs"
add wave sim:/bitonic_sorter_tb/sorted_indices
add wave sim:/bitonic_sorter_tb/done_sort

# ============================================================
# Run simulation
# ============================================================
run -all



