`default_nettype none
(* use_dsp = "no" *)
module astro_pixrep (
  input  wire          clk,
  input  wire          rst,
  input  wire [11:0]   cfg_thd_on,
  input  wire [11:0]   cfg_thd_off,
  input  wire [11:0]   cfg_thh_on,
  input  wire [11:0]   cfg_thh_off,
  input  wire [4:0]    cfg_dwell,
  input  wire          in_valid,
  input  wire [127:0]  in_data,
  output wire          in_ready,
  output reg           out_valid,
  output reg  [127:0]  out_data,
  output reg  [7:0]    out_flags,
  output reg           out_last
);
  localparam integer NW = 2048;
  localparam integer NSW = 20;
  localparam [1:0] S_IN = 2'd1, S_SW = 2'd2;

  reg [1:0]  st;
  reg [11:0] icnt;
  reg [11:0] pcnt;
  reg [4:0]  sw;
  reg [11:0] ri;
  reg [11:0] spc;

  (* ram_style = "block", cascade_height = 1, rw_addr_collision = "yes" *) reg [159:0] trm  [0:NW-1];
  (* ram_style = "block", cascade_height = 1, rw_addr_collision = "yes" *) reg [95:0]  stm  [0:NW-1];
  (* ram_style = "block", cascade_height = 1, rw_addr_collision = "yes" *) reg [135:0] amem [0:NW-1];

  assign in_ready = (st == S_IN) && (icnt < NW);
  wire acc = in_valid & in_ready;

  reg [159:0] tr_rd, tr_rd2;
  reg [127:0] cnt1, cnt2;
  reg         v1, v2;
  reg [10:0]  a1, a2;

  reg         fresh;
  wire [159:0] tro = fresh ? 160'd0 : tr_rd2;
  reg [159:0] trn;
  integer j;
  reg [8:0]  aa;
  reg signed [21:0] df;
  always @(*) begin
    for (j = 0; j < 8; j = j + 1) begin
      aa = {1'b0, cnt2[16*j +: 8]} + {1'b0, cnt2[16*j+8 +: 8]};
      df = $signed({2'b00, aa, 11'd0}) - $signed({2'b00, tro[20*j +: 20]});
      trn[20*j +: 20] = tro[20*j +: 20] + df[20:9] + {{8{df[21]}}, 12'd0};
    end
  end

  wire fpush_dummy = (st == S_IN) && (icnt == NW) && !v1 && !v2 && (pcnt >= NW) && (pcnt < NW + 17);
  wire fpush = v2 | fpush_dummy;

  reg [159:0] dt [0:34];
  reg [127:0] dc [0:34];
  reg         fv;
  reg [10:0]  fc;

  wire [6:0] fy = fc[10:4];
  wire [3:0] fw = fc[3:0];
  wire       ry = (fy == 7'd0) || (fy == 7'd127);
  wire [159:0] aL = (fy == 7'd0) ? 160'd0 : dt[34];
  wire [159:0] aC = (fy == 7'd0) ? 160'd0 : dt[33];
  wire [159:0] aR = (fy == 7'd0) ? 160'd0 : dt[32];
  wire [159:0] bL = (fy == 7'd127) ? 160'd0 : dt[2];
  wire [159:0] bC = (fy == 7'd127) ? 160'd0 : dt[1];
  wire [159:0] bR = (fy == 7'd127) ? 160'd0 : dt[0];
  wire [159:0] mL = dt[18];
  wire [159:0] mC = dt[17];
  wire [159:0] mR = dt[16];

  function [19:0] tl;
    input [159:0] Lw, Cw;
    input [3:0] w;
    input integer jj;
    begin
      if (jj > 0) tl = Cw[20*(jj-1) +: 20];
      else if (w == 4'd0) tl = 20'd0;
      else tl = Lw[140 +: 20];
    end
  endfunction

  function [19:0] tr_;
    input [159:0] Cw, Rw;
    input [3:0] w;
    input integer jj;
    begin
      if (jj < 7) tr_ = Cw[20*(jj+1) +: 20];
      else if (w == 4'd15) tr_ = 20'd0;
      else tr_ = Rw[0 +: 20];
    end
  endfunction

  reg [22:0] ssum [0:7];
  reg [23:0] tnn  [0:7];
  reg        rx;
  reg [19:0] tc;
  always @(*) begin
    for (j = 0; j < 8; j = j + 1) begin
      ssum[j] = tl(aL, aC, fw, j) + aC[20*j +: 20] + tr_(aC, aR, fw, j)
              + tl(mL, mC, fw, j) + tr_(mC, mR, fw, j)
              + tl(bL, bC, fw, j) + bC[20*j +: 20] + tr_(bC, bR, fw, j);
      rx = ((j == 0) && (fw == 4'd0)) || ((j == 7) && (fw == 4'd15));
      tc = mC[20*j +: 20];
      if (ry && rx) tnn[j] = {4'd0, tc} + {3'd0, tc, 1'b0};
      else if (ry || rx) tnn[j] = {4'd0, tc} + {2'd0, tc, 2'b0};
      else tnn[j] = {1'b0, tc, 3'b0};
    end
  end

  reg         f1v, f2v;
  reg [10:0]  f1c, f2c;
  reg [22:0]  f1s [0:7];
  reg [23:0]  f1t [0:7];
  reg [127:0] f1n, f2n;
  reg [95:0]  st0, st1, st2;
  wire [95:0] sto = fresh ? 96'd0 : st2;
  reg [34:0]  f2do [0:7];
  reg [34:0]  f2df [0:7];
  reg [34:0]  f2ho [0:7];
  reg [34:0]  f2hf [0:7];
  reg [34:0]  f2l  [0:7];

  reg [7:0]   fflag;
  reg [127:0] fzero;
  reg [95:0]  stn;
  reg         don, doff, hon, hoff, odf, ohf, ndf, nhf;
  reg [4:0]   odc, ohc;
  reg [5:0]   ndc, nhc;
  always @(*) begin
    for (j = 0; j < 8; j = j + 1) begin
      don  = f2l[j] < f2do[j];
      doff = f2l[j] > f2df[j];
      hon  = f2l[j] > f2ho[j];
      hoff = f2l[j] < f2hf[j];
      odf = sto[12*j + 11];
      ohf = sto[12*j + 10];
      odc = sto[12*j + 5 +: 5];
      ohc = sto[12*j +: 5];
      ndc = (odf ? doff : don) ? {1'b0, odc} + 1'b1 : 6'd0;
      nhc = (ohf ? hoff : hon) ? {1'b0, ohc} + 1'b1 : 6'd0;
      ndf = odf;
      nhf = ohf;
      if (ndc >= {1'b0, cfg_dwell}) begin ndf = ~odf; ndc = 6'd0; end
      if (nhc >= {1'b0, cfg_dwell}) begin nhf = ~ohf; nhc = 6'd0; end
      stn[12*j +: 12] = {ndf, nhf, ndc[4:0], nhc[4:0]};
      fflag[j] = ndf | nhf;
      fzero[16*j +: 16] = fflag[j] ? 16'd0 : f2n[16*j +: 16];
    end
  end

  reg          rv, rv1;
  reg  [135:0] ard, ard2;
  wire [135:0] srd = ard2;
  wire         epush_dummy = (st == S_SW) && !rv && !rv1 && (ri == NW) && (spc >= NW) && (spc < NW + 16);
  wire         epush = rv | epush_dummy;
  reg  [135:0] el [0:32];
  reg          ev;
  reg  [10:0]  ec;

  wire [6:0] ey = ec[10:4];
  wire [3:0] ew = ec[3:0];
  wire [135:0] eC = el[16];
  wire [135:0] eN = (ey == 7'd0) ? 136'd0 : el[32];
`ifdef BUG_EDGEPAD
  wire       etop = 1'b0;
`else
  wire       etop = (ey == 7'd0);
`endif
  wire [135:0] eS = (ey == 7'd127) ? 136'd0 : el[0];
  wire [135:0] eL = el[17];
  wire [135:0] eR = el[15];

  reg [127:0] enew;
  integer p;
  reg [7:0]  vn, vs, vw, ve;
  reg [9:0]  vsum;
  reg [19:0] v3;
  reg [2:0]  n4;
  always @(*) begin
    for (j = 0; j < 8; j = j + 1) begin
      n4 = 3'd4 - etop - (ey == 7'd127) - ((j == 0) && (ew == 4'd0)) - ((j == 7) && (ew == 4'd15));
      for (p = 0; p < 2; p = p + 1) begin
        vn = eN[16*j+8*p +: 8];
        vs = eS[16*j+8*p +: 8];
        if (j > 0) vw = eC[16*(j-1)+8*p +: 8];
        else if (ew == 4'd0) vw = 8'd0;
        else vw = eL[112+8*p +: 8];
        if (j < 7) ve = eC[16*(j+1)+8*p +: 8];
        else if (ew == 4'd15) ve = 8'd0;
        else ve = eR[8*p +: 8];
        vsum = {2'b0, vn} + {2'b0, vs} + {2'b0, vw} + {2'b0, ve};
        v3 = {10'd0, vsum} * 20'd683;
        enew[16*j+8*p +: 8] = !eC[128+j] ? eC[16*j+8*p +: 8] :
                              (n4 == 3'd4) ? vsum[9:2] : (n4 == 3'd3) ? v3[18:11] : vsum[8:1];
      end
    end
  end

  wire        rd_en = (st == S_SW) && (ri < NW);
  wire        a_we = (st == S_IN) ? f2v : ev;
  wire [10:0] a_wa = (st == S_IN) ? f2c : ec;
  wire [135:0] a_wd = (st == S_IN) ? {fflag, fzero} : {eC[135:128], enew};

  always @(posedge clk) begin
    if (acc) tr_rd <= trm[icnt[10:0]];
    tr_rd2 <= tr_rd;
    if (v2) trm[a2] <= trn;
    if (fpush) st0 <= stm[pcnt[10:0] - 11'd17];
    st1 <= st0;
    if (f2v) stm[f2c] <= stn;
    if (rd_en) ard <= amem[ri[10:0]];
    ard2 <= ard;
    if (a_we) amem[a_wa] <= a_wd;
  end

  integer i;
  always @(posedge clk) begin
    cnt1 <= in_data;
    cnt2 <= cnt1;
    a1 <= icnt[10:0];
    a2 <= a1;
    if (fpush) begin
      dt[0] <= v2 ? trn : 160'd0;
      dc[0] <= v2 ? cnt2 : 128'd0;
      for (i = 0; i < 34; i = i + 1) begin
        dt[i+1] <= dt[i];
        dc[i+1] <= dc[i];
      end
    end
    f1c <= fc;
    f1n <= dc[17];
    for (i = 0; i < 8; i = i + 1) begin
      f1s[i] <= ssum[i];
      f1t[i] <= tnn[i];
      f2do[i] <= cfg_thd_on * f1s[i];
      f2df[i] <= cfg_thd_off * f1s[i];
      f2ho[i] <= cfg_thh_on * f1s[i];
      f2hf[i] <= cfg_thh_off * f1s[i];
      f2l[i] <= {1'b0, f1t[i], 10'd0};
    end
    f2c <= f1c;
    f2n <= f1n;
    st2 <= st1;
    if (epush) begin
      el[0] <= rv ? srd : 136'd0;
      for (i = 0; i < 32; i = i + 1) el[i+1] <= el[i];
    end
    out_data <= enew;
    out_flags <= eC[135:128];
    out_last <= (ec == 11'd2047);
  end

  always @(posedge clk) begin
    if (rst) begin
      st <= S_IN;
      fresh <= 1'b1;
      icnt <= 12'd0;
      pcnt <= 12'd0;
      v1 <= 1'b0;
      v2 <= 1'b0;
      rv1 <= 1'b0;
      fv <= 1'b0;
      f1v <= 1'b0;
      f2v <= 1'b0;
      rv <= 1'b0;
      ev <= 1'b0;
      sw <= 5'd0;
      ri <= 12'd0;
      spc <= 12'd0;
      out_valid <= 1'b0;
    end else begin
      v1 <= acc;
      v2 <= v1;
      f1v <= fv;
      f2v <= f1v;
      rv1 <= rd_en;
      rv <= rv1;
      out_valid <= ev && (sw == NSW - 1);
      if (acc) icnt <= icnt + 1'b1;
      if (fpush) begin
        pcnt <= pcnt + 1'b1;
        fv <= (pcnt >= 12'd17);
        fc <= pcnt[10:0] - 11'd17;
      end else begin
        fv <= 1'b0;
      end
      if (rd_en) ri <= ri + 1'b1;
      if (epush) begin
        spc <= spc + 1'b1;
        ev <= (spc >= 12'd16);
        ec <= spc[10:0] - 11'd16;
      end else begin
        ev <= 1'b0;
      end
      case (st)
        S_IN: if (f2v && f2c == NW - 1) begin
          st <= S_SW;
          fresh <= 1'b0;
          sw <= 5'd0;
          ri <= 12'd0;
          spc <= 12'd0;
        end
        S_SW: if (ev && ec == NW - 1) begin
          ri <= 12'd0;
          spc <= 12'd0;
          if (sw == NSW - 1) begin
            st <= S_IN;
            icnt <= 12'd0;
            pcnt <= 12'd0;
          end else begin
            sw <= sw + 1'b1;
          end
        end
        default: st <= S_IN;
      endcase
    end
  end
endmodule
`default_nettype wire
