vsim -gui work.bitonic_sorter_msb_tb

# ============================================================
# Clock & Reset
# ============================================================
add wave -divider "Clock & Reset"
add wave sim:/bitonic_sorter_msb_tb/clk
add wave sim:/bitonic_sorter_msb_tb/rst

# ============================================================
# Inputs
# ============================================================
add wave -divider "Inputs"
add wave sim:/bitonic_sorter_msb_tb/LLR_mag
add wave sim:/bitonic_sorter_msb_tb/DUT/sort_en

# ============================================================
# Runtime parameters
# ============================================================
add wave -divider "Runtime parameters"
add wave sim:/bitonic_sorter_msb_tb/DUT/n_r
add wave sim:/bitonic_sorter_msb_tb/DUT/load_en

# ============================================================
# Magnitude & Index Pipeline Registers
# ============================================================
add wave -divider "Mag,Index regs"
add wave sim:/bitonic_sorter_msb_tb/DUT/mag_stages
add wave sim:/bitonic_sorter_msb_tb/DUT/idx_stages
add wave sim:/bitonic_sorter_msb_tb/DUT/lsb_lut

# ============================================================
# Valid Pipeline Control
# ============================================================
add wave -divider "Valid Pipeline Control"
add wave sim:/bitonic_sorter_msb_tb/DUT/stage_valid

# ============================================================
# Outputs
# ============================================================
add wave -divider "Outputs"
add wave sim:/bitonic_sorter_msb_tb/sorted_indices
add wave sim:/bitonic_sorter_msb_tb/done_sort

# ============================================================
# Run simulation
# ============================================================
run -all



