`timescale 1ns/1ps
`default_nettype none
module c2_tbank (
  input wire clk,
  input wire we,
  input wire [10:0] wa,
  input wire [15:0] wd,
  input wire [10:0] ra,
  output reg [15:0] q = 16'd0
);
  (* ram_style = "block" *) reg [15:0] mem [0:2047];
  reg [15:0] q1 = 16'd0;
  always @(posedge clk) begin
    if (we) mem[wa] <= wd;
    q1 <= mem[ra];
    q <= q1;
  end
endmodule

module c2_mmram (
  input wire clk,
  input wire we,
  input wire [9:0] wa,
  input wire [31:0] wd,
  input wire [9:0] ra,
  output reg [31:0] q = 32'd0
);
  (* ram_style = "block" *) reg [31:0] mem [0:1023];
  reg [31:0] q1 = 32'd0;
  always @(posedge clk) begin
    if (we) mem[wa] <= wd;
    q1 <= mem[ra];
    q <= q1;
  end
endmodule

module c2_tile (
  input wire clk, rst, go,
  input wire t_co, t_li, t_mm,
  input wire [31:0] t_addr,
  input wire [3:0] t_lg,
  input wire [23:0] t_count,
  output wire idle,
  input wire e_valid,
  input wire [31:0] e_data,
  output wire e_hold,
  output wire l_valid,
  output wire [31:0] l_data,
  input wire l_ready,
  output wire rq_v,
  output wire [31:0] rq_a,
  output wire [4:0] rq_n,
  input wire rq_g,
  input wire rd_v,
  input wire [127:0] rd_d,
  output wire wq_v,
  output wire [31:0] wq_a,
  output wire [4:0] wq_n,
  input wire wq_g,
  output wire [127:0] wd_d,
  output wire [15:0] wd_s,
  input wire wd_pop,
  output reg err_v = 1'b0,
  output reg [3:0] err_code = 4'd0
);
  localparam S_IDLE = 2'd0, S_CO = 2'd1, S_LI = 2'd2, S_MM = 2'd3;
  reg [1:0] st = S_IDLE;
  reg [31:0] base = 32'd0;
  reg [3:0] lg = 4'd0;
  reg [23:0] ntiles = 24'd0;

  reg [10:0] wa, ra;
  reg [7:0] we_lo, we_hi;
  reg [127:0] wdl, wdh;
  wire [15:0] ql [0:7];
  wire [15:0] qh [0:7];
  genvar g;
  generate for (g = 0; g < 8; g = g + 1) begin: g_bank
    c2_tbank u_lo (.clk(clk), .we(we_lo[g]), .wa(wa), .wd(wdl[16*g +: 16]), .ra(ra), .q(ql[g]));
    c2_tbank u_hi (.clk(clk), .we(we_hi[g]), .wa(wa), .wd(wdh[16*g +: 16]), .ra(ra), .q(qh[g]));
  end endgenerate
  wire [127:0] qlo = {ql[7], ql[6], ql[5], ql[4], ql[3], ql[2], ql[1], ql[0]};
  wire [127:0] qhi = {qh[7], qh[6], qh[5], qh[4], qh[3], qh[2], qh[1], qh[0]};

  reg fb = 1'b0;
  reg [13:0] wc = 14'd0;
  reg [1:0] full = 2'b00;
  reg [23:0] tfill = 24'd0, tdone = 24'd0;
  reg [23:0] tile0 = 24'd0, tile1 = 24'd0;
  reg flb = 1'b0;
  reg [10:0] fj = 11'd0;
  reg frd1 = 1'b0, frd = 1'b0, fph = 1'b0;
  reg [127:0] fodd = 128'd0;
  reg [31:0] fodd_a = 32'd0;

  reg [11:0] mi = 12'd0;
  reg mp1 = 1'b0, mpend = 1'b0, mh1 = 1'b0, mhalf = 1'b0;
  reg [95:0] mbeat = 96'd0;
  reg [1:0] mw = 2'd0;
  reg [8:0] mbi = 9'd0;

  reg [9:0] mm_ra;
  reg [9:0] s0_idx = 10'd0, s1_idx = 10'd0;
  reg [15:0] s0_lo = 16'd0, s0_hi = 16'd0, s1_lo = 16'd0, s1_hi = 16'd0;
  reg s0_v = 1'b0, s0_init = 1'b0, s1_v = 1'b0, s1_init = 1'b0;
  wire [31:0] mqe, mqo;
  wire signed [15:0] ome_min = mqe[15:0], ome_max = mqe[31:16];
  wire signed [15:0] omo_min = mqo[15:0], omo_max = mqo[31:16];
  wire signed [15:0] slo = s1_lo, shi = s1_hi;
  wire [31:0] nme = s1_init ? {s1_lo, s1_lo} : {(slo > ome_max) ? s1_lo : mqe[31:16], (slo < ome_min) ? s1_lo : mqe[15:0]};
  wire [31:0] nmo = s1_init ? {s1_hi, s1_hi} : {(shi > omo_max) ? s1_hi : mqo[31:16], (shi < omo_min) ? s1_hi : mqo[15:0]};
  c2_mmram u_mme (.clk(clk), .we(s1_v), .wa(s1_idx), .wd(nme), .ra(mm_ra), .q(mqe));
  c2_mmram u_mmo (.clk(clk), .we(s1_v), .wa(s1_idx), .wd(nmo), .ra(mm_ra), .q(mqo));

  wire [5:0] wfc, wac;
  reg wpush;
  reg [127:0] wpd;
  reg [31:0] wpa;
  wire [31:0] wah;
  wire wav;
  c2_fifo_d #(.W(128), .AW(5)) u_wd (.clk(clk), .rst(rst), .wr(wpush), .din(wpd), .rd(wd_pop), .dout(wd_d), .dv(), .count(wfc));
  c2_fifo_d #(.W(32), .AW(5)) u_wa (.clk(clk), .rst(rst), .wr(wpush), .din(wpa), .rd(wq_g), .dout(wah), .dv(wav), .count(wac));
  assign wd_s = 16'hffff;
  assign wq_v = wav && go;
  assign wq_a = wah;
  assign wq_n = 5'd1;

  reg lb = 1'b0;
  reg [1:0] rdy = 2'b00;
  reg [23:0] lfill = 24'd0, lfed = 24'd0, ltile = 24'd0;
  reg [11:0] lreq = 12'd0, lrcv = 12'd0;
  reg lfilling = 1'b0;
  reg kb = 1'b0;
  reg [13:0] fw = 14'd0;
  reg p1 = 1'b0, pv = 1'b0;
  reg [2:0] ps1 = 3'd0, psel = 3'd0;
  wire [3:0] ocnt;
  wire ov;
  wire [31:0] od;
  wire opop = ov && l_ready;
  c2_fifo_d #(.W(32), .AW(3)) u_of (.clk(clk), .rst(rst), .wr(pv), .din({qh[psel], ql[psel]}), .rd(opop), .dout(od), .dv(ov), .count(ocnt));
  assign l_valid = ov;
  assign l_data = od;
  wire [10:0] lcf = {lreq[3:1], lreq[0], lreq[10:4]};
  wire [31:0] laddr = base + (((({21'd0, lcf}) << lg) + ltile[21:0]) << 4);
  assign rq_v = st == S_LI && lfilling && !lreq[11] && go;
  assign rq_a = laddr;
  assign rq_n = 5'd1;

  wire [10:0] fcf = {fj[2:0], 1'b0, fj[9:3]};
  wire [23:0] ftile = flb ? tile1 : tile0;
  wire [31:0] faddr_e = base + (((({21'd0, fcf}) << lg) + ftile[21:0]) << 4);
  wire [31:0] faddr_o = base + (((({21'd0, fcf | 11'd128}) << lg) + ftile[21:0]) << 4);

  assign e_hold = st == S_CO && wc >= 14'd8191 && full[~fb];
  assign idle = st == S_IDLE && wac == 6'd0 && wfc == 6'd0;

  wire fl_go = st == S_CO && full[flb] && !frd1 && !frd && !fph && wfc < 6'd28;
  wire ld_go = st == S_LI && rdy[kb] && !fw[13] && (ocnt + p1 + pv) < 4'd6;
  wire mm_go = st == S_MM && !mi[11] && !mp1 && !mpend && wfc < 6'd28;
  wire [31:0] mword = mhalf ? mqo : mqe;

  always @* begin
    wa = 11'd0; we_lo = 8'd0; we_hi = 8'd0; wdl = 128'd0; wdh = 128'd0;
    if (st == S_CO && e_valid) begin
      wa = {fb, wc[9:0]};
      we_lo[wc[12:10]] = 1'b1; we_hi[wc[12:10]] = 1'b1;
`ifdef BUG_TILE
      if (wc[12:10] == 3'd5) begin we_lo[wc[12:10]] = 1'b0; we_lo[3'd4] = 1'b1; end
`endif
      wdl = {8{e_data[15:0]}}; wdh = {8{e_data[31:16]}};
    end else if (st == S_LI && rd_v) begin
      wa = {lb, lrcv[10:1]};
      if (lrcv[0]) we_hi = 8'hff; else we_lo = 8'hff;
      wdl = rd_d; wdh = rd_d;
    end
    ra = st == S_CO ? {flb, fj[9:0]} : {kb, fw[9:0]};
    mm_ra = st == S_MM ? {mi[6:0], mi[10:8]} : wc[9:0];
    wpush = 1'b0; wpd = 128'd0; wpa = 32'd0;
    if (frd) begin wpush = 1'b1; wpd = qlo; wpa = faddr_e; end
    else if (fph) begin wpush = 1'b1; wpd = fodd; wpa = fodd_a; end
    else if (mpend && mw == 2'd3) begin wpush = 1'b1; wpd = {mword, mbeat}; wpa = base + {19'd0, mbi, 4'd0}; end
  end

  always @(posedge clk) begin
    err_v <= 1'b0;
    s0_v <= 1'b0;
    s1_v <= s0_v;
    s1_idx <= s0_idx; s1_lo <= s0_lo; s1_hi <= s0_hi; s1_init <= s0_init;
    if (rst) begin
      st <= S_IDLE; fb <= 1'b0; wc <= 0; full <= 2'b00; tfill <= 0; tdone <= 0; flb <= 1'b0; fj <= 0; frd1 <= 1'b0; frd <= 1'b0; fph <= 1'b0;
      mi <= 0; mp1 <= 1'b0; mpend <= 1'b0; mw <= 0; mbi <= 0;
      lb <= 1'b0; rdy <= 2'b00; lfill <= 0; lfed <= 0; lreq <= 0; lrcv <= 0; lfilling <= 1'b0; kb <= 1'b0; fw <= 0; p1 <= 1'b0; pv <= 1'b0;
    end else begin
      p1 <= ld_go;
      pv <= p1;
      if (st == S_IDLE) begin
        base <= t_addr; lg <= t_lg; ntiles <= t_count;
        if (t_co) begin st <= S_CO; fb <= 1'b0; wc <= 0; full <= 2'b00; tfill <= 0; tdone <= 0; flb <= 1'b0; fj <= 0; end
        if (t_li) begin st <= S_LI; lb <= 1'b0; rdy <= 2'b00; lfill <= 0; lfed <= 0; lreq <= 0; lrcv <= 0; lfilling <= t_count != 0; ltile <= 0; kb <= 1'b0; fw <= 0; end
        if (t_mm) begin st <= S_MM; mi <= 0; mp1 <= 1'b0; mpend <= 1'b0; mw <= 0; mbi <= 0; end
        if (e_valid) begin err_v <= 1'b1; err_code <= 4'd12; end
      end
      if (st == S_CO) begin
        if (e_valid) begin
          s0_v <= 1'b1; s0_idx <= wc[9:0]; s0_lo <= e_data[15:0]; s0_hi <= e_data[31:16];
          s0_init <= tfill == 24'd0 && wc[13:10] == 4'd0;
          if (wc == 14'd8192) begin err_v <= 1'b1; err_code <= 4'd13; end
          if (wc == 14'd8191) begin
            full[fb] <= 1'b1; tfill <= tfill + 1'b1;
            if (fb) tile1 <= tfill; else tile0 <= tfill;
          end
          wc <= wc + 1'b1;
        end else if (wc == 14'd8192 && !full[~fb]) begin
          fb <= ~fb; wc <= 0;
        end
        frd1 <= fl_go;
        frd <= frd1;
        if (frd) begin fodd <= qhi; fodd_a <= faddr_o; fph <= 1'b1; end
        if (fph) begin
          fph <= 1'b0;
          fj <= fj + 1'b1;
          if (fj == 11'd1023) begin fj <= 0; full[flb] <= 1'b0; flb <= ~flb; tdone <= tdone + 1'b1; end
        end
        if (tdone == ntiles && !frd1 && !frd && !fph && !fl_go) st <= S_IDLE;
      end
      if (st == S_LI) begin
        if (rq_g) lreq <= lreq + 1'b1;
        if (rd_v) begin
          lrcv <= lrcv + 1'b1;
          if (lrcv == 12'd2047) begin
            rdy[lb] <= 1'b1; lb <= ~lb; lfill <= lfill + 1'b1; lreq <= 0; lrcv <= 0; lfilling <= 1'b0;
          end
        end else if (!lfilling && lfill < ntiles && !rdy[lb] && lreq == 12'd0) begin
          lfilling <= 1'b1; ltile <= lfill;
        end
        ps1 <= fw[12:10];
        psel <= ps1;
        if (ld_go) begin
          fw <= fw + 1'b1;
          if (fw == 14'd8191) begin fw <= 0; rdy[kb] <= 1'b0; kb <= ~kb; lfed <= lfed + 1'b1; end
        end
        if (lfed == ntiles && ocnt == 4'd0 && !p1 && !pv) st <= S_IDLE;
      end
      if (st == S_MM) begin
        mp1 <= mm_go;
        mpend <= mp1;
        mhalf <= mh1;
        if (mm_go) begin mi <= mi + 1'b1; mh1 <= mi[7]; end
        if (mpend) begin
          mw <= mw + 1'b1;
          if (mw == 2'd3) mbi <= mbi + 1'b1;
          else mbeat[32*mw +: 32] <= mword;
        end
        if (mi[11] && !mp1 && !mpend) st <= S_IDLE;
      end
    end
  end
endmodule
`default_nettype wire
