library ieee;
  use ieee.std_logic_1164.all;
  use ieee.numeric_std.all;
  use ieee.math_real.all;
  use work.config_pkg.all;

entity reduced_precision_sorter is
  generic (
    n_max  : integer := 256;
    B_mag  : integer := 5;
    LW_MAX : integer := 104
  );
  port (clk, rst       : in  std_logic;
        n              : in  integer range 1 to n_max;
        sort_en        : in  std_logic;
        LLR_mag        : in  std_logic_vector(n_max * B_mag - 1 downto 0);          -- all input magnitudes packed into one vector
        sorted_indices : out std_logic_vector(LW_MAX * WIDTH_INDICES - 1 downto 0); -- final permutation vector, each index has log2(N) bits
        done_sort      : out std_logic
       );
end entity;

architecture pipeline_stage of reduced_precision_sorter is

  -- Function to round n up to next power of two
  function ceil_pow2(x : integer) return integer is
  begin
    if x <= 1 then
      return 1;
    elsif x <= 2 then
      return 2;
    elsif x <= 4 then
      return 4;
    elsif x <= 8 then
      return 8;
    elsif x <= 16 then
      return 16;
    elsif x <= 32 then
      return 32;
    elsif x <= 64 then
      return 64;
    elsif x <= 128 then
      return 128;
    else
      return 256;
    end if;
  end function;

  function int_log2_ceil(x : integer) return integer is
  begin
    if x <= 1 then
      return 0;
    elsif x <= 2 then
      return 1;
    elsif x <= 4 then
      return 2;
    elsif x <= 8 then
      return 3;
    elsif x <= 16 then
      return 4;
    elsif x <= 32 then
      return 5;
    elsif x <= 64 then
      return 6;
    elsif x <= 128 then
      return 7;
    else
      return 8;
    end if;
  end function;

  -- Constants
  constant LOGN_MAX  : integer := int_log2_ceil(n_max);
  constant MSB_NUM   : integer := 3;
  
  -- Type definitions
  type mag_array is array (0 to n_max - 1) of unsigned(MSB_NUM - 1 downto 0); --holds the magnitudes
  type index_array is array (0 to n_max - 1) of unsigned(WIDTH_INDICES - 1 downto 0); --holds the indices associated with each magnitude

  -- Stage arrays(each stage takes the output of the previous one as its input)
  type mag_stage_array is array (0 to LOGN_MAX) of mag_array; --stores the LLR magnitudes of all sorting stages(2D array [stage][element])
  type index_stage_array is array (0 to LOGN_MAX) of index_array; --stores the index order evolution through stages(2D array [stage][index])
  
  -- Mask for which sorting stages are active for the current n_effective
  signal active_stage : std_logic_vector(LOGN_MAX - 1 downto 0) := (others => '0');

  -- Mask for which lanes belong to the rounded-up power-of-two (n_effective)
  type mask_array is array (0 to n_max - 1) of std_logic;
  signal active_mask : mask_array := (others => '0');

  -- Signals
  signal mag_stages  : mag_stage_array;                                        -- main data pipeline of the sorter
  signal idx_stages  : index_stage_array;                                      -- companion pipeline for the permutation vector
  signal stage_valid : std_logic_vector(LOGN_MAX downto 0) := (others => '0'); -- marks which stage has valid data (shift register for latency tracking)
  signal done_sort_r : std_logic                           := '0';             -- register flag for done_sort output
  signal n_r         : integer range 0 to n_max            := 0;               -- Registered version of runtime parameter n
  signal load_en     : std_logic                           := '0';             -- signal to enable loading of new data
  signal sort_en_d   : std_logic                           := '0';             -- delayed version of sort_en to create a load enable pulse one cycle after sort_en goes high

begin
  -- output flag when sorting is done
  done_sort <= done_sort_r;

     -- Configuration + active mask + active stages + dynamic tie start
  process (clk, rst)
    variable n_effective : integer range 0 to n_max;
    variable logn_eff    : integer range 0 to LOGN_MAX;
  begin
    if rst = '1' then
      n_r         <= 0;
      active_mask <= (others => '0');
      active_stage <= (others => '0');

    elsif rising_edge(clk) then
      if sort_en = '1' then
        n_r <= n;
        n_effective := ceil_pow2(n);
        logn_eff := int_log2_ceil(n_effective);

        -- Active lanes belong to the rounded-up active problem size
        for i in 0 to n_max - 1 loop
          if i < n_effective then
            active_mask(i) <= '1';
          else
            active_mask(i) <= '0';
          end if;
        end loop;

        -- Active sorting stages
        for st in 0 to LOGN_MAX - 1 loop
          if st < logn_eff then
            active_stage(st) <= '1';
          else
            active_stage(st) <= '0';
          end if;
        end loop;
      end if;
    end if;
  end process;
  
 process (clk, rst)
  begin
    if rst = '1' then
      sort_en_d <= '0';
    elsif rising_edge(clk) then
      sort_en_d <= sort_en;
    end if;
  end process;

  load_en <= sort_en_d;

  -- Stage 0 (load LLR magnitudes,initialize indices)
  process (clk, rst)
  begin
    if (rst = '1') then
      for i in 0 to n_max - 1 loop
        mag_stages(0)(i) <= (others => '0');
        idx_stages(0)(i) <= (others => '0');
      end loop;

    elsif rising_edge(clk) then
      --Take a single flat vector (LLR_mag) that contains all magnitudes concatenated together
      --and splits it into an array of individual unsigned elements(use for compare and swap)
      if load_en = '1' then -- Only load when new data arrives
        for i in 0 to n_max - 1 loop
          if i < n_r then
            mag_stages(0)(i) <= unsigned(LLR_mag((i + 1) * B_mag - 1 downto (i + 1) * B_mag - MSB_NUM));
            idx_stages(0)(i) <= to_unsigned(i, WIDTH_INDICES);
          elsif active_mask(i) = '1' then -- i < n_effective 
            mag_stages(0)(i) <= (others => '1');
            idx_stages(0)(i) <= to_unsigned(i, WIDTH_INDICES);
          else
            mag_stages(0)(i) <= (others => '0');
            idx_stages(0)(i) <= (others => '0');
          end if;
        end loop;
      end if;
    end if;
  end process;

  -- shifting process to enable stages only when inputs are valid
  valid_pipeline: process (clk, rst)
  begin
    if rst = '1' then
      stage_valid <= (others => '0');
      done_sort_r <= '0';

    elsif rising_edge(clk) then
      -- default pulse low
      done_sort_r <= '0';

      -- launch valid token
      stage_valid(0) <= load_en;

      -- shift token
      for s in 1 to LOGN_MAX loop
        stage_valid(s) <= stage_valid(s - 1);
      end loop;

      -- done detection
      if stage_valid(LOGN_MAX) = '1' then
        done_sort_r <= '1';
      end if;
    end if;
  end process;

  -- Generate all Bitonic sorting stages
  gen_stages: for s in 0 to LOGN_MAX - 1 generate --generate loop (the stages log2n)
  begin
    process (clk, rst)
      variable dist         : integer; --Distance between elements to be compared in that substage [ 2**(s-k) ]
      variable seq_len      : integer; --Length of the current bitonic sequence being sorted (ascending or descending) [ 2**(s+1) ]
      variable partner      : integer range 0 to n_max - 1; --Index of the element being compared with the current one
      variable dir_asc      : boolean;
      variable mag_a, mag_b : unsigned(MSB_NUM - 1 downto 0);
      variable idx_a, idx_b : unsigned(WIDTH_INDICES - 1 downto 0);
      variable tmp_mag      : mag_array;
      variable tmp_idx      : index_array;
	  variable do_swap      : boolean;
    begin
      if rst = '1' then
        for i in 0 to n_max - 1 loop
          mag_stages(s + 1)(i) <= (others => '0');
          idx_stages(s + 1)(i) <= (others => '0');
        end loop;

      elsif rising_edge(clk) then
        for i in 0 to n_max - 1 loop
          tmp_mag(i) := mag_stages(s)(i);
          tmp_idx(i) := idx_stages(s)(i);
        end loop;

        if stage_valid(s) = '1' then
		
		  -- only active stages perform sorting;
          -- inactive stages remain pass-through
          if active_stage(s) = '1' then
          -- this stage corresponds to bitonic sequence length 2**(s+1)
          seq_len := 2 ** (s + 1);

          -- walk substages k = 0..s (combinational), with dist = 2**(s-k)
          for k in 0 to s loop
            dist := 2 ** (s - k);

            --only operate once per pair: when (i and dist)=0
            for i in 0 to n_max - 1 loop

              if active_mask(i) = '1' then

                partner := to_integer(unsigned(to_unsigned(i, WIDTH_INDICES) xor to_unsigned(dist, WIDTH_INDICES))); -- partner = i xor dist
                dir_asc := (i mod (2 * seq_len)) < seq_len; -- same logic as dir_asc = (i and seq_len) = 0 -> Ascending direction for the first half of each bitonic sequence

                -- Only perform compare & swap (ascending / descending) on active elements
                if (active_mask(partner) = '1') and (unsigned(to_unsigned(i, WIDTH_INDICES) and to_unsigned(dist, WIDTH_INDICES)) = 0) then
                  -- (i and dist = 0) process only one member of each XOR group (the one whose dist-bit is 0),while (partner > i) duplicate pairs

                  -- read current working buffers
                  mag_a := tmp_mag(i);
                  mag_b := tmp_mag(partner);
                  idx_a := tmp_idx(i);
                  idx_b := tmp_idx(partner);
			
                  if dir_asc then
                      do_swap := (mag_a > mag_b);
                  else
                      do_swap := (mag_a < mag_b);
                  end if;

                  if do_swap then
                    tmp_mag(i) := mag_b;
                    tmp_mag(partner) := mag_a;
                    tmp_idx(i) := idx_b;
                    tmp_idx(partner) := idx_a;
                  end if;
                end if;
			        end if;
           end loop;
         end loop;
		  end if;
          -- register stage output
          for j in 0 to n_max - 1 loop
            mag_stages(s + 1)(j) <= tmp_mag(j);
            idx_stages(s + 1)(j) <= tmp_idx(j);
          end loop;
        end if;
      end if;
    end process;
  end generate;

  -- Sorted indices output process
  process (clk, rst)
  begin
    if rst = '1' then
      sorted_indices <= (others => '0');
    elsif rising_edge(clk) then
      if done_sort_r = '1' then
        for i in 0 to LW_MAX - 1 loop -- the system supports LW_MAX = 104, we only need the 104th least reliable bit in the worst case (W.C.)
          --Takes the sorted indices array (index_array) and packs it back into one wide vector for output
          sorted_indices((i + 1) * WIDTH_INDICES - 1 downto i * WIDTH_INDICES) <= std_logic_vector(idx_stages(LOGN_MAX)(i));
        end loop;
      end if;
    end if;
  end process;

end architecture;
