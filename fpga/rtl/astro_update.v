`default_nettype none
module astro_update #(
  parameter integer DEPTH = 2816,
  parameter integer QW = 32
) (
  input  wire               clk,
  input  wire               rst,
  input  wire [17:0]        cfg_eta_fast,
  input  wire [17:0]        cfg_eta_slow,
  input  wire               st_start,
  input  wire               st_buf,
  input  wire [4:0]         st_slot,
  input  wire [3:0]         st_t,
  input  wire               st_fault,
  input  wire [15:0]        st_nbase,
  input  wire [1:0]         st_bank,
  input  wire               q_valid,
  input  wire               q_buf,
  input  wire [6:0]         q_level,
  input  wire signed [31:0] q_data,
  output reg                b_valid,
  output reg  [6:0]         b_level,
  output reg  signed [QW:0] b_tq,
  output reg  signed [QW-1:0] b_qbar,
  output reg  [1:0]         b_bank,
  output reg                b_fault,
  input  wire               h_en,
  input  wire               h_we,
  input  wire               h_sel,
  input  wire [11:0]        h_addr,
  input  wire [2*QW-1:0]    h_wdata,
  output reg  [2*QW-1:0]    h_rdata
);
  reg [4:0]  cslot [0:1];
  reg        cfault [0:1];
  reg [1:0]  cbank [0:1];
  reg [17:0] caf [0:1];
  reg [17:0] cas [0:1];

  reg        gbusy, gbuf;
  reg [4:0]  gcnt;
  reg [17:0] gd;
  reg [17:0] grem;
  reg [24:0] gq;
  wire [18:0] gr2 = {grem, (gcnt == 5'd24)};
  wire        gge = (gr2 >= {1'b0, gd});
  wire [17:0] gnext = gge ? (gr2 - {1'b0, gd}) : gr2[17:0];
  wire [24:0] gqn = {gq[23:0], gge};

  always @(posedge clk) begin
    if (rst) begin
      gbusy <= 1'b0;
    end else begin
      if (st_start) begin
        gd <= {2'b0, st_nbase} + {14'b0, st_t} + 18'd65;
        grem <= 18'd0;
        gq <= 25'd0;
        gcnt <= 5'd24;
        gbusy <= 1'b1;
        gbuf <= st_buf;
        cslot[st_buf] <= st_slot;
        cfault[st_buf] <= st_fault;
        cbank[st_buf] <= st_bank;
      end else if (gbusy) begin
        grem <= gnext;
        gq <= gqn;
        gcnt <= gcnt - 1'b1;
        if (gcnt == 5'd0) begin
          gbusy <= 1'b0;
          caf[gbuf] <= (gqn[17:0] > cfg_eta_fast) ? gqn[17:0] : cfg_eta_fast;
          cas[gbuf] <= (gqn[17:0] > cfg_eta_slow) ? gqn[17:0] : cfg_eta_slow;
        end
      end
    end
  end

  (* ram_style = "ultra" *) reg [2*QW-1:0] mema [0:DEPTH-1];
  (* ram_style = "ultra" *) reg [2*QW-1:0] memb [0:DEPTH-1];
  reg [2*QW-1:0] ra1, ra2, rb1, rb2, ha1, ha2, hb1, hb2;
  reg        hs1, hs2;

  wire [11:0] rd_addr = {cslot[q_buf], q_level};

  reg         uw;
  reg  [11:0] uaddr;
  reg  [2*QW-1:0] udata;
  wire        pa_en = uw | (h_en & ~h_sel);
  wire        pa_we = uw | h_we;
  wire [11:0] pa_addr = uw ? uaddr : h_addr;
  wire [2*QW-1:0] pa_din = uw ? udata : h_wdata;
  wire        pb_en = h_en & h_sel;

  always @(posedge clk) begin
    if (q_valid) begin
      ra1 <= mema[rd_addr];
      rb1 <= memb[rd_addr];
    end
    ra2 <= ra1;
    rb2 <= rb1;
  end

  always @(posedge clk) begin
    if (pa_en) begin
      if (pa_we) mema[pa_addr] <= pa_din;
      else ha1 <= mema[pa_addr];
    end
  end

  always @(posedge clk) begin
    if (pb_en) begin
      if (h_we) memb[h_addr] <= h_wdata;
      else hb1 <= memb[h_addr];
    end
  end

  always @(posedge clk) begin
    ha2 <= ha1;
    hb2 <= hb1;
    hs1 <= h_sel;
    hs2 <= hs1;
    h_rdata <= hs2 ? hb2 : ha2;
  end

  reg               v [1:10];
  reg [6:0]         lv [1:10];
  reg [11:0]        ad [1:10];
  reg               fa [1:10];
  reg [1:0]         bk [1:10];
  reg signed [31:0] qd [1:2];
  reg [17:0]        af [1:2];
  reg [17:0]        as_ [1:2];
  reg signed [QW-1:0] qb [3:9];
  reg signed [QW-1:0] dd [3:8];
  reg signed [QW-1:0] lo [3:8];
  reg signed [QW-1:0] hi [3:8];
  reg signed [35:0] e3;
  reg [17:0]        a3;
  (* use_dsp = "yes" *) reg signed [54:0] m4;
  reg signed [54:0] m5, m6;
  reg signed [30:0] dl7;
  reg signed [QW+1:0] dn8;
  reg signed [QW-1:0] dc9;
  reg signed [QW:0] tr10;
  reg signed [QW-1:0] qb10;
  reg signed [QW:0] tq_prev;

  wire signed [QW-1:0] r_qb = ra2[2*QW-1:QW];
  wire signed [QW-1:0] r_d  = ra2[QW-1:0];
  wire signed [QW-1:0] r_lo = rb2[2*QW-1:QW];
  wire signed [QW-1:0] r_hi = rb2[QW-1:0];
  wire signed [35:0] e2 = $signed({{4{qd[2][31]}}, qd[2]} <<< 8) - $signed({{(36-QW){r_qb[QW-1]}}, r_qb}) - $signed({{(36-QW){r_d[QW-1]}}, r_d});
  wire               epos = ~e2[35] & (|e2);
  wire signed [54:0] rnd = m6 + 55'sd8388608;
  wire signed [QW+1:0] lo8 = $signed({{2{lo[8][QW-1]}}, lo[8]});
  wire signed [QW+1:0] hi8 = $signed({{2{hi[8][QW-1]}}, hi[8]});
`ifdef BUG_CLIP
  wire signed [QW+1:0] cl0 = dn8;
`else
  wire signed [QW+1:0] cl0 = (dn8 > hi8) ? hi8 : dn8;
`endif
  wire signed [QW+1:0] cl1 = (cl0 < lo8) ? lo8 : cl0;
`ifdef BUG_RMAX
  wire signed [QW:0] tq11 = tr10;
`else
  wire signed [QW:0] tq11 = (lv[10] == 7'd0 || tr10 > tq_prev) ? tr10 : tq_prev;
`endif

  integer i;
  always @(posedge clk) begin
    if (rst) begin
      for (i = 1; i <= 10; i = i + 1) v[i] <= 1'b0;
      uw <= 1'b0;
      b_valid <= 1'b0;
    end else begin
      v[1] <= q_valid;
      for (i = 1; i < 10; i = i + 1) v[i+1] <= v[i];
      uw <= v[9] & fa[9];
      b_valid <= v[10];
    end
    lv[1] <= q_level;
    ad[1] <= rd_addr;
    fa[1] <= cfault[q_buf];
    bk[1] <= cbank[q_buf];
    qd[1] <= q_data;
    af[1] <= caf[q_buf];
    as_[1] <= cas[q_buf];
    for (i = 1; i < 10; i = i + 1) begin
      lv[i+1] <= lv[i];
      ad[i+1] <= ad[i];
      fa[i+1] <= fa[i];
      bk[i+1] <= bk[i];
    end
    qd[2] <= qd[1];
    af[2] <= af[1];
    as_[2] <= as_[1];

    e3 <= e2;
    a3 <= epos ? af[2] : as_[2];
    qb[3] <= r_qb;
    dd[3] <= r_d;
    lo[3] <= r_lo;
    hi[3] <= r_hi;
    for (i = 3; i < 9; i = i + 1) qb[i+1] <= qb[i];
    for (i = 3; i < 8; i = i + 1) begin
      dd[i+1] <= dd[i];
      lo[i+1] <= lo[i];
      hi[i+1] <= hi[i];
    end

    m4 <= $signed({1'b0, a3}) * e3;
    m5 <= m4;
    m6 <= m5;
    dl7 <= rnd[54:24];
    dn8 <= $signed({{2{dd[7][QW-1]}}, dd[7]}) + $signed({{(QW-29){dl7[30]}}, dl7});
    dc9 <= fa[8] ? cl1[QW-1:0] : dd[8];

    uaddr <= ad[9];
    udata <= {qb[9], dc9};
    tr10 <= $signed({qb[9][QW-1], qb[9]}) + $signed({dc9[QW-1], dc9});
    qb10 <= qb[9];

    if (v[10]) tq_prev <= tq11;
    b_level <= lv[10];
    b_tq <= tq11;
    b_qbar <= qb10;
    b_bank <= bk[10];
    b_fault <= fa[10];
  end
endmodule
`default_nettype wire
