`default_nettype none
module msx (
  input         clk25_mhz,
  // Buttons
  input [6:0]   btn,
  // HDMI
  output [3:0]  gpdi_dp,
  output [3:0]  gpdi_dn,
  // Keyboard
  output        usb_fpga_pu_dp,
  output        usb_fpga_pu_dn,
  inout         ps2Clk,
  inout         ps2Data,
  // Audio
  output [3:0]  audio_l,
  output [3:0]  audio_r,
  // ESP32 passthru
  input         ftdi_txd,
  output        ftdi_rxd,
  input         wifi_txd,
  output        wifi_rxd,  // SPI from ESP32
  input         wifi_gpio16,
  input         wifi_gpio5,
  output        wifi_gpio0,

  inout  sd_clk, sd_cmd,
  inout   [3:0] sd_d,

  inout  [27:0] gp,gn,
  // Leds
  output [7:0]  leds
);

  parameter c_vga_out = 0;
  parameter c_diag = 1;

  // Used for interrupt to ESP32
  assign wifi_gpio0 = 0;

  // pull-ups for us2 connector 
  assign usb_fpga_pu_dp = 1;
  assign usb_fpga_pu_dn = 1;
  
  // passthru to ESP32 micropython serial console
  assign wifi_rxd = ftdi_txd;
  assign ftdi_rxd = wifi_txd;

  // VGA (should be assigned to some gp/gn outputs
  wire   [7:0]  red;
  wire   [7:0]  green;
  wire   [7:0]  blue;
  wire          hSync;
  wire          vSync;
  
  generate
    genvar i;
    if (c_vga_out) begin
      for(i = 0; i < 4; i = i+1) begin
        assign gp[10-i] = red[4+i];
        assign gn[3-i] = green[4+i];
        assign gn[10-i] = blue[4+i];
      end
      assign gp[2] = vSync;
      assign gp[3] = hSync;
    end 
  endgenerate

  reg [15:0] diag16;

  generate 
    genvar i;
    if (c_diag) begin
      for(i = 0; i < 4; i = i+1) begin
        assign gn[17-i] = diag16[8+i];
        assign gp[17-i] = diag16[12+i];
        assign gn[24-i] = diag16[i];
        assign gp[24-i] = diag16[4+i];
      end
    end
  endgenerate
  
  wire          n_WR;
  wire          n_RD;
  wire          n_INT;
  wire [15:0]   cpuAddress;
  wire [7:0]    cpuDataOut;
  wire [7:0]    cpuDataIn;
  wire          n_memWR;
  wire          n_memRD;
  wire          n_ioWR;
  wire          n_ioRD;
  wire          n_MREQ;
  wire          n_IORQ;
  wire          n_M1;
  wire          n_kbdCS;
  wire          n_int;

  reg [3:0]     cpuClockCount;
  wire          cpuClock;
  wire          cpuClockEnable;
  reg           cpuClockEnable1; 
  wire          cpuClockEdge = cpuClockEnable && !cpuClockEnable1;
  wire [7:0]    ramOut;

  // ===============================================================
  // System Clock generation
  // ===============================================================
  wire clk_hdmi, clk_vga;

  pll pll_i (
    .clkin(clk25_mhz),
    .clkout0(clk_hdmi),
    .clkout1(clk_vga),
    .clkout2(cpuClock)
  );

  // ===============================================================
  // Reset generation
  // ===============================================================
  reg [15:0] pwr_up_reset_counter = 0;
  wire       pwr_up_reset_n = &pwr_up_reset_counter;

  always @(posedge cpuClock) begin
     if (!pwr_up_reset_n)
       pwr_up_reset_counter <= pwr_up_reset_counter + 1;
  end

  // ===============================================================
  // CPU
  // ===============================================================
  wire [15:0] pc;
  
  wire n_hard_reset = pwr_up_reset_n & btn[0];

  tv80n cpu1 (
    .reset_n(n_hard_reset),
    //.clk(cpuClock), // turbo mode 28MHz
    .clk(cpuClockEnable), // normal mode 3.5MHz
    .wait_n(!scroll),
    .int_n(n_int),
    .nmi_n(1'b1),
    .busrq_n(1'b1),
    .mreq_n(n_MREQ),
    .m1_n(n_M1),
    .iorq_n(n_IORQ),
    .wr_n(n_WR),
    .rd_n(n_RD),
    .A(cpuAddress),
    .di(cpuDataIn),
    .do(cpuDataOut),
    .pc(pc)
  );

  // ===============================================================
  // RAM
  // ===============================================================
  ram #(
    .MEM_INIT_FILE("../roms/msx.mem")
  )
  ram64 (
    .clk(cpuClock),
    .we(!n_memWR),
    .addr(cpuAddress),
    .din(cpuDataOut),
    .dout(ramOut)
  );

  // ===============================================================
  // Keyboard
  // ===============================================================
  wire [10:0] ps2_key;

    // Get PS/2 keyboard events
  ps2 ps2_kbd (
     .clk(cpuClock),
     .ps2_clk(ps2Clk),
     .ps2_data(ps2Data),
     .ps2_key(ps2_key)
  );

  // Keyboard matrix
  wire       pause, scroll, reso;
  wire [7:0] f_keys;
  wire [7:0] ppi_port_b;
  wire [7:0] key_diag;
  reg [7:0]  ppi_port_a;
  reg [7:0]  ppi_port_c;

  keyboard key_board (
    .clk(cpuClock),
    .reset(!n_hard_reset),
    .clk_ena(1'b1),
    .k_map(1'b1), // English
    .pause(pause),
    .scroll(scroll),
    .reso(reso),
    .f_keys(f_keys),
    .ps2_key(ps2_key),
    .ppi_port_c(ppi_port_c),
    .p_key_x(ppi_port_b),
    .diag(key_diag)
  );

  // ===============================================================
  // VGA
  // ===============================================================
  wire        vga_de;
  wire [7:0]  vga_dout;
  reg  [13:0] vga_addr;
  wire        vga_wr = cpuAddress[7:0] == 8'h98 && n_ioWR == 1'b0;
  wire        vga_rd = cpuAddress[7:0] == 8'h98 && n_ioRD == 1'b0;
  reg         is_second_addr_byte = 0;
  reg [7:0]   first_addr_byte;
  reg [7:0]   r_vdp [0:7];
  wire [1:0]  mode = r_vdp[1][3] ? 3 : r_vdp[0][1] ? 2 : r_vdp[1][4] ? 0 : 1;
  wire [13:0] name_table_addr = r_vdp[2] * 1024;
  wire [13:0] color_table_addr = r_vdp[3][7] * 16'h2000;
  wire [13:0] font_addr = mode == 2 ? r_vdp[4][2] * 8192 : r_vdp[4] * 2048;
  wire [13:0] sprite_attr_addr = r_vdp[5] * 128;
  wire [13:0] sprite_pattern_table_addr = r_vdp[6] * 2048;
  wire [7:0]  vga_diag;
  reg         r_vga_rd;
  reg [3:0]   r_psg;
  wire [4:0]  sprite5;
  wire        sprite_collision;
  wire        too_many_sprites;
  wire        interrupt_flag;

  always @(posedge cpuClock) begin
    if (cpuClockEdge) begin
      if (cpuAddress[7:0] == 8'ha0 && n_ioWR == 1'b0) r_psg <= cpuDataOut[3:0];
      // VDP interface
      if (vga_wr) vga_addr <= vga_addr + 1;
      // Increment address on CPU cycle after IO read
      r_vga_rd <= vga_rd;
      if (r_vga_rd && !vga_rd) vga_addr <= vga_addr + 1;

      if (cpuAddress[7:0] == 8'h99 && n_ioWR == 1'b0) begin
        is_second_addr_byte <= ~is_second_addr_byte;
        if (is_second_addr_byte) begin
          if (!cpuDataOut[7]) begin
            vga_addr <=  {cpuDataOut[5:0], first_addr_byte};
          end else begin
            if (cpuDataOut[5:0] < 8) begin
              r_vdp[cpuDataOut[5:0]] <= first_addr_byte;
            end
          end
        end else begin
          first_addr_byte <= cpuDataOut;
        end
      end
      // PPI interface
      if (cpuAddress[7:0] == 8'ha8 && n_ioWR == 1'b0)
        ppi_port_a <= cpuDataOut;
      if (cpuAddress[7:0] == 8'haa && n_ioWR == 1'b0)
        ppi_port_c <= cpuDataOut;
      if (cpuAddress[7:0] == 8'hab && n_ioWR == 1'b0 && !cpuDataOut[7])
        ppi_port_c[cpuDataOut[3:1]] <= cpuDataOut[0];
    end
  end
      
  video vga (
    .clk(clk_vga),
    .vga_r(red),
    .vga_g(green),
    .vga_b(blue),
    .vga_de(vga_de),
    .vga_hs(hSync),
    .vga_vs(vSync),
    .vga_addr(vga_addr),
    .vga_din(cpuDataOut),
    .vga_dout(vga_dout),
    .vga_wr(vga_wr && cpuClockEdge),
    .vga_rd(vga_rd && cpuClockEdge),
    .mode(mode),
    .cpu_clk(cpuClock),
    .font_addr(font_addr),
    .name_table_addr(name_table_addr),
    .color_table_addr(color_table_addr),
    .sprite_attr_addr(sprite_attr_addr),
    .sprite_pattern_table_addr(sprite_pattern_table_addr),
    .n_int(n_int),
    .video_on(r_vdp[1][6]),
    .text_color(r_vdp[7][7:4]),
    .back_color(r_vdp[7][3:0]),
    .sprite_large(r_vdp[1][1]),
    .sprite_enlarged(r_vdp[1][0]),
    .vert_retrace_int(r_vdp[1][5]),
    .sprite_collision(sprite_collision),
    .too_many_sprites(too_many_sprites),
    .sprite5(sprite5),
    .interrupt_flag(interrupt_flag),
    .diag(vga_diag)
  );

  // Convert VGA to HDMI
  HDMI_out vga2dvid (
    .pixclk(clk_vga),
    .pixclk_x5(clk_hdmi),
    .red  (red),
    .green(green),
    .blue (blue),
    .vde(vga_de),
    .hSync(hSync),
    .vSync(vSync),
    .gpdi_dp(gpdi_dp),
    .gpdi_dn(gpdi_dn)
  );

  // ===============================================================
  // MEMORY READ/WRITE LOGIC
  // ===============================================================

  assign n_ioWR  = n_WR | n_IORQ;
  assign n_memWR = n_WR | n_MREQ;
  assign n_ioRD  = n_RD | n_IORQ;
  assign n_memRD = n_RD | n_MREQ;

  // ===============================================================
  // Memory decoding
  // ===============================================================

  reg  r_interrupt_flag, r_sprite_collision;
  reg  r_status_read;
  wire [7:0] status = {r_interrupt_flag, too_many_sprites, r_sprite_collision, (too_many_sprites ? sprite5 : 5'b11111)};
  wire [7:0] joystick = {2'b0, ~btn[2:1], ~btn[6:3]};

  assign cpuDataIn =  cpuAddress[7:0] == 8'ha8 && n_ioRD == 1'b0 ? ppi_port_a :
                      cpuAddress[7:0] == 8'ha9 && n_ioRD == 1'b0 ? ppi_port_b :
                      cpuAddress[7:0] == 8'haa && n_ioRD == 1'b0 ? ppi_port_c :
                      cpuAddress[7:0] == 8'h98 && n_ioRD == 1'b0 ? vga_dout :
                      cpuAddress[7:0] == 8'h99 && n_ioRD == 1'b0 ? status :
		      cpuAddress[7:0] == 8'ha2 && n_ioRD == 1'b0 && r_psg == 14 ? joystick :
                      ramOut;

  always @(posedge cpuClock) begin
    if (!n_hard_reset) begin
      r_interrupt_flag <= 0;
      r_sprite_collision <= 0;
    end else begin
      if (interrupt_flag) r_interrupt_flag <= 1;
      if (sprite_collision) r_sprite_collision <= 1;
      if (cpuClockEdge) begin
        r_status_read <= cpuAddress[7:0] == 8'h99 && n_ioRD == 1'b0;
        if (r_status_read && !(cpuAddress[7:0] == 8'h99 && n_ioRD == 1'b0)) begin
          r_interrupt_flag <= 0;
          r_sprite_collision <= 0;
        end
      end
    end
  end
  
  // ===============================================================
  // CPU clock enable
  // ===============================================================
  
  always @(posedge cpuClock) begin
    cpuClockEnable1 <= cpuClockEnable;
    cpuClockCount <= cpuClockCount + 1;
  end

  assign cpuClockEnable = cpuClockCount[2]; // 3.5Mhz

  // ===============================================================
  // Audio
  // ===============================================================
  wire [9:0] sound_10;
  assign audio_l = sound_10[7:4] | {2{ppi_port_c[7]}};
  assign audio_r = audio_l;

  jt49 #(.CLKDIV(6)) audio (
    .rst_n(n_hard_reset),
    .clk(cpuClock),
    .clk_en(cpuClockEnable),
    .addr(r_psg),
    .cs_n(1'b0),
    .wr_n(n_ioWR || cpuAddress[7:0] != 8'ha1),
    .din(cpuDataOut),
    .sel(1'b1),
    .sound(sound_10)
  );

  // ===============================================================
  // Leds
  // ===============================================================
  wire led1 = !n_kbdCS;
  wire led2 = 0;
  wire led3 = 0;
  wire led4 = !n_hard_reset;

  assign leds = {led4, led3, led2, led1};

  always @(posedge cpuClock) if (status[6] && status[4:0] != 0) diag16 <= status;

endmodule
