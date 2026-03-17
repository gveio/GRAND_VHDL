library ieee;
  use ieee.std_logic_1164.all;

  -- The controller enforces the order: LOAD, CHECK_HD, SORT, S_GEN_GUESSES, S_CHECK_GUESSES, DONE

entity controller is
  port (
    clk              : in  std_logic;
    rst              : in  std_logic;

    -- External start
    dec_en           : in  std_logic;

    -- Handshake from datapath
    llr_done_sig     : in  std_logic;
    memb_done_sig    : in  std_logic;
    valid_sig        : in  std_logic;
    done_sort_sig    : in  std_logic;
    abandon_sig      : in  std_logic;
    patt_done_sig    : in  std_logic;
    guess_done_sig   : in  std_logic;

    -- Enables to datapath
    llr_en           : out std_logic;
    start_memb_check : out std_logic;
    sort_en          : out std_logic;
    pattern_en       : out std_logic;

    -- Select for y_in MUX of membership/error checker
    y_sel            : out std_logic;

    -- Final decode status
    dec_done         : out std_logic
  );
end entity;

architecture fsm of controller is

  type state_type is (
      S_INIT,          -- Wait for dec_en = 1
      S_LOAD,          -- Run LLR extraction
      S_CHECK_HD,      -- First membership check
      S_SORT,          -- Bitonic sorter
      S_GEN_GUESSES,   -- Start guessing phase for current LW/HW pair
      S_CHECK_GUESSES, -- Membership check on guessed vectors for current LW/HW pair
      S_DONE -- Decode done (valid guess or abandon)
    );

  signal state, next_state : state_type;
  signal start_check_reg   : std_logic := '0'; -- use start_check_reg as one single clean pulse when entering to CHECK states 
  signal sort_pulse_reg    : std_logic := '0'; -- use start_pulse_reg as one single clean pulse when entering to S_SORT

begin

  -- STATE REGISTER
  process (clk, rst)
  begin
    if rst = '1' then
      state <= S_INIT;
      start_check_reg <= '0';

    elsif rising_edge(clk) then
      state <= next_state;

      -- default
      sort_pulse_reg <= '0';
      start_check_reg <= '0';

      -- Pulse sorter ON ENTRY to S_SORT
      if next_state = S_SORT and state /= S_SORT then
        sort_pulse_reg <= '1';
      end if;

      -- hard decision membership check pulse
      if next_state = S_CHECK_HD and state /= S_CHECK_HD then
        start_check_reg <= '1';
      end if;

      -- guessed membership check pulse so as to align with correct y_check
      if patt_done_sig = '1' and (state = S_GEN_GUESSES or state = S_CHECK_GUESSES) then
        start_check_reg <= '1';
      end if;

    end if;
  end process;

  -- NEXT STATE LOGIC
  process (state, dec_en, llr_done_sig, memb_done_sig, valid_sig, done_sort_sig, abandon_sig, guess_done_sig)
  begin

    next_state <= state;

    case state is

      when S_INIT =>
        if dec_en = '1' then
          next_state <= S_LOAD;
        end if;

      when S_LOAD =>
        if llr_done_sig = '1' then
          next_state <= S_CHECK_HD;
        end if;

      when S_CHECK_HD =>
        if memb_done_sig = '1' then
          if valid_sig = '1' then
            next_state <= S_DONE; -- already valid
          else
            next_state <= S_SORT; -- need guesses
          end if;
        end if;

      when S_SORT =>
        if done_sort_sig = '1' then
          next_state <= S_GEN_GUESSES;
        end if;

      when S_GEN_GUESSES =>
        -- Wait for current guess to finish
        if guess_done_sig = '1' then
          -- guess is valid now, can immediately go check it
          next_state <= S_CHECK_GUESSES;
        end if;

      when S_CHECK_GUESSES =>
        -- You should check valid_sig, abandon_sig only when the membership result for this guess is ready
        if memb_done_sig = '1' then
          if valid_sig = '1' or abandon_sig = '1' then -- Found valid codeword or guesses exhausted
            next_state <= S_DONE;
          elsif guess_done_sig = '1' then
            -- guess is valid now, can immediately go check it
            next_state <= S_CHECK_GUESSES;
          else
            next_state <= S_GEN_GUESSES;
          end if;
        end if;

      when S_DONE =>
        next_state <= S_INIT;

      when others =>
        next_state <= S_INIT;

    end case;
  end process;

  -- LLR loader
  llr_en <= '1' when state = S_LOAD else '0';

  -- membership checker enable
  start_memb_check <= start_check_reg;

  -- sorter enable
  sort_en <= sort_pulse_reg;

  -- pattern/error generation active during guess phases
  pattern_en <= '1' when (state = S_GEN_GUESSES or state = S_CHECK_GUESSES) else
                '0';

  -- 0: use y_hard, 1: use y_guessed
  -- Use guessed vector only during TEP loop
  y_sel <= '1' when (state = S_GEN_GUESSES or state = S_CHECK_GUESSES) else
           '0';

  -- decode finished
  dec_done <= '1' when state = S_DONE else '0';

end architecture;
