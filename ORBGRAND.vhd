library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;
  use ieee.math_real.all;
  use work.types_pkg.all;
  use work.config_pkg.all;

entity ORBGRAND is
  generic (
    n_max  : integer := 256;
    nk_max : integer := 16;
    B      : integer := 6;
    B_mag  : integer := 5;
    LW_MAX : integer := 104;
    HW_MAX : integer := 13
  );

  port (
    clk, rst      : in  std_logic;
    n             : in  integer range 1 to n_max;
    nk            : in  integer range 1 to nk_max;
    dec_en        : in  std_logic;
    H_matrix_id   : in  integer range 0 to NUM_CODES - 1;
    LLR_in        : in  std_logic_vector(n_max * B - 1 downto 0);
    y_decoded     : out std_logic_vector(n_max - 1 downto 0);
    dec_done      : out std_logic;
    query_cnt_dbg : out integer
  );
end entity;

architecture arch of ORBGRAND is

  -- Handshake & datapath signals
  signal LLR_mag_sig  : std_logic_vector(n_max * B_mag - 1 downto 0);
  signal y_hard_sig   : std_logic_vector(n_max - 1 downto 0);
  signal llr_done_sig : std_logic;

  signal H_sel                  : H_matrix_type;
  signal start_memb_check_sig   : std_logic;
  signal start_memb_check_gated : std_logic;
  signal memb_done_sig          : std_logic;
  signal valid_sig              : std_logic;
  signal syndrome_sig           : std_logic_vector(nk_max - 1 downto 0);

  signal sorted_indices_sig : std_logic_vector(LW_MAX * WIDTH_INDICES - 1 downto 0);
  signal done_sort_sig      : std_logic;

  signal pattern_sig          : std_logic_vector(HW_MAX * WIDTH_PATTERN - 1 downto 0);
  signal pattern_en_gated     : std_logic;
  signal per_pattern_done_sig : std_logic;
  signal pattern_done_sig     : std_logic;
  signal abandon_sig          : std_logic;
  signal LW_sig               : integer range 1 to LW_MAX;
  signal HW_sig               : integer range 1 to HW_MAX;

  signal error_en_gated : std_logic;
  signal noise_vec_sig  : std_logic_vector(n_max - 1 downto 0);
  signal y_guessed_sig  : std_logic_vector(n_max - 1 downto 0);
  signal error_done_sig : std_logic;

  -- Controller enable outputs
  signal llr_en_sig     : std_logic;
  signal sort_en_sig    : std_logic;
  signal pattern_en_sig : std_logic;
  signal y_sel_sig      : std_logic;

  -- MUX input for checker
  signal y_check     : std_logic_vector(n_max - 1 downto 0);
  signal y_check_reg : std_logic_vector(n_max - 1 downto 0);

  -- Register for decoded codeword
  signal y_decoded_r : std_logic_vector(n_max - 1 downto 0);

  -- Flag to latch the correct decoded codeword
  signal found_valid : std_logic := '0';

  -- synthesis translate_off
  signal query_cnt : integer := 0;
  -- synthesis translate_on

begin
  -- The controller enforces the order: LOAD, CHECK_HD, SORT, S_GEN_GUESSES, S_CHECK_GUESSES, DONE
  -- Decoding starts
  -- LLRs are extracting in LLR_mag for sorter and y_hard for codebook membership check
  -- Codebook membership check on the received y_hard with membership/error checker
  -- If codeword is valid then decoding done otherwise sorter begins
  -- Then pattern generator begins producing patterns
  -- Error generator uses pattern and sorted list to flip bits and construct noise vector and with y_hard to construct the y_guessed
  -- Membership check on the y_guessed with error checker
  -- If codeword is valid then decoding done otherwise the rest error patterns are tested until maximum queries reached
  process (H_matrix_id)
  begin
    case H_matrix_id is
      when 0 => H_sel <= H_CAPOLAR_128_116;
      when 1 => H_sel <= H_BCH_127_113;
      when 2 => H_sel <= H_PAC_128_116;
      when 3 => H_sel <= H_CRC_Ox8f3_128_116;
      when 4 => H_sel <= H_CRC_0xd175_256_240;
      when 5 => H_sel <= H_CAPOLAR_256_240;
      when others => H_sel <= H_CAPOLAR_128_116;
    end case;
  end process;

  -- CONTROLLER FSM
  fsm: entity work.controller
    port map (
      clk              => clk,
      rst              => rst,
      dec_en           => dec_en,

      -- handshakes from datapath
      llr_done_sig     => llr_done_sig,
      memb_done_sig    => memb_done_sig,
      valid_sig        => valid_sig,
      done_sort_sig    => done_sort_sig,
      abandon_sig      => abandon_sig,
      patt_done_sig    => per_pattern_done_sig,
      guess_done_sig   => error_done_sig,

      -- enables to datapath
      llr_en           => llr_en_sig,
      start_memb_check => start_memb_check_sig,
      sort_en          => sort_en_sig,
      pattern_en       => pattern_en_sig,

      -- Select for y_in MUX of membership/error checker
      y_sel            => y_sel_sig,

      -- final decode
      dec_done         => dec_done
    );

  -- Since the same block is used to perform a membership check, first on the received demodulated sequence
  -- and later on the guessed sequence produced by the error generator, a multiplexer is used to select the input of the error checker
  with y_sel_sig select
    y_check <= y_hard_sig          when '0',
               y_guessed_sig       when '1',
                   (others => '0') when others;

  -- Valid-gating for membership/error checker, pattern generator and error generator
  start_memb_check_gated <= start_memb_check_sig and not (found_valid or valid_sig);
  pattern_en_gated       <= pattern_en_sig and not (found_valid or valid_sig);
  error_en_gated         <= per_pattern_done_sig and not (found_valid or valid_sig);

  process (clk, rst)
  begin
    if rst = '1' then
      y_check_reg <= (others => '0');
      -- The hard vector is latched exactly once and every guessed vector is latched only if we have not yet found a valid codeword 
    elsif rising_edge(clk) then
      if start_memb_check_gated = '1' and abandon_sig = '0' then
        y_check_reg <= y_check;
      end if;
    end if;
  end process;

  -- Decoded codeword
  output_buffer: process (clk, rst)
  begin
    if rst = '1' then
      y_decoded_r <= (others => '0');
      found_valid <= '0';

    elsif rising_edge(clk) then
      if dec_en = '1' then
        -- reset for new decode
        y_decoded_r <= (others => '0');
        found_valid <= '0';
      end if;

      -- latch only the FIRST valid result
      if (valid_sig = '1' or abandon_sig = '1') and found_valid = '0' then
        y_decoded_r <= y_check_reg; -- always correct decoded vector
        found_valid <= '1';
      end if;

    end if;
  end process;

  y_decoded <= y_decoded_r;

  process (clk)
  begin
    if rising_edge(clk) then
      if rst = '1' then
        query_cnt <= 0;

      elsif dec_en = '1' then
        query_cnt <= 0;

      elsif start_memb_check_gated = '1' then
        query_cnt <= query_cnt + 1;
      end if;
    end if;
  end process;

  query_cnt_dbg <= query_cnt;

  -- LLR INPUT / HARD DECISION EXTRACTION
  input_buffer: entity work.llrs_in
    generic map (
      n_max => n_max,
      B     => B
    )
    port map (
      clk       => clk,
      rst       => rst,
      n         => n,
      llr_en    => llr_en_sig,
      LLR_in    => LLR_in,
      LLR_mag   => LLR_mag_sig,
      y_hard    => y_hard_sig,
      load_done => llr_done_sig
    );

  -- MEMBERSHIP/ERROR CHECKER
  memb_error_check: entity work.error_checker
    generic map (
      n_max  => n_max,
      nk_max => nk_max
    )
    port map (clk              => clk,
              rst              => rst,
              n                => n,
              nk               => nk,
              H_matrix_in      => H_sel,
              y_in             => y_check,
              start_memb_check => start_memb_check_gated,
              syn_out          => syndrome_sig,
              memb_check_done  => memb_done_sig,
              valid_memb_check => valid_sig
    );

  -- Patterns from pattern generator
  pattern_gen: entity work.pattern_generator
    generic map (
      LW_MAX => LW_MAX,
      HW_MAX => HW_MAX
    )
    port map (
      clk              => clk,
      rst              => rst,
      gen_en           => pattern_en_gated,
      pattern          => pattern_sig,
      per_pattern_done => per_pattern_done_sig,
      pattern_done     => pattern_done_sig,
      abandon          => abandon_sig,
      LW_dbg           => LW_sig,
      HW_dbg           => HW_sig
    );

  -- Error vectors and estimated y vectors from error generator
  error_gen: entity work.error_generator
    generic map (
      n_max  => n_max,
      LW_MAX => LW_MAX,
      HW_MAX => HW_MAX
    )
    port map (
      clk            => clk,
      rst            => rst,
      error_en       => error_en_gated,
      pattern        => pattern_sig,
      sorted_indices => sorted_indices_sig,
      y_hard         => y_hard_sig,
      noise_vec      => noise_vec_sig,
      y_guessed      => y_guessed_sig,
      error_done     => error_done_sig
    );

  -- Sorted list of indices from the sorter
  bitonic_sorter: entity work.bitonic_sorter_msb
    generic map (
      n_max => n_max,
      B_mag => B_mag
    )
    port map (
      clk            => clk,
      rst            => rst,
      n              => n,
      sort_en        => sort_en_sig,
      LLR_mag        => LLR_mag_sig,
      sorted_indices => sorted_indices_sig,
      done_sort      => done_sort_sig
    );

end architecture;
