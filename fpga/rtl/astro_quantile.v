`default_nettype none
module astro_quantile #(
  parameter integer W    = 16,
  parameter integer NMAX = 16384,
  parameter integer NB   = 1024,
  parameter integer F    = 8,
  parameter integer SHW  = 3
) (
  input  wire                 clk,
  input  wire                 rst,
  input  wire signed [W-1:0]  cfg_offset,
  input  wire [SHW-1:0]       cfg_shift,
  input  wire                 in_valid,
  input  wire                 in_last,
  input  wire signed [W-1:0]  in_data,
  output wire                 in_ready,
  output wire                 fill_buf,
  output reg                  out_valid,
  output reg                  out_last,
  output reg  [6:0]           out_level,
  output reg  signed [31:0]   out_data,
  output reg                  out_buf
);
  localparam integer BW  = $clog2(NB);
  localparam integer CW  = $clog2(NMAX + 1);
  localparam integer RKW = $clog2(NMAX);
  localparam integer EW  = W + 2;
  localparam integer VW  = W + F + 2;
  localparam integer DW  = CW + 1;
  localparam integer PW  = 32;
  localparam integer NI  = 8;

  localparam [1:0] B_EMPTY = 2'd0, B_FULL = 2'd1, B_SCAN = 2'd2;
  localparam [1:0] F_CLR = 2'd0, F_WAIT = 2'd1, F_IN = 2'd2, F_DRAIN = 2'd3;

  reg [1:0] bst0, bst1;
  reg [1:0] fst;
  reg       fb, sb, scanning;
  reg [1:0] wdn, odn;
  reg [BW-1:0] clr_a;

  assign in_ready = (fst == F_IN);
  assign fill_buf = fb;
  wire accept = in_valid & in_ready;

  (* ram_style = "block" *) reg [CW-1:0] mem0 [0:NB-1];
  (* ram_style = "block" *) reg [CW-1:0] mem1 [0:NB-1];
  reg [CW-1:0] rd0, rd1, do0, do1;
  reg          we0, we1;
  reg [BW-1:0] wa0, wa1, ra0, ra1;
  reg [CW-1:0] wd0, wd1;

  always @(posedge clk) begin
    if (we0) mem0[wa0] <= wd0;
    rd0 <= mem0[ra0];
    do0 <= rd0;
  end
  always @(posedge clk) begin
    if (we1) mem1[wa1] <= wd1;
    rd1 <= mem1[ra1];
    do1 <= rd1;
  end

  wire signed [W:0] dsub = $signed({in_data[W-1], in_data}) - $signed({cfg_offset[W-1], cfg_offset});
  wire [W-1:0] ushift = dsub[W-1:0] >> cfg_shift;
  wire [BW-1:0] bin_in = dsub[W] ? {BW{1'b0}} : (ushift >= NB) ? NB - 1 : ushift[BW-1:0];

  reg          v1, v2, v3, f1_v, f2_v;
  reg [BW-1:0] a1, a2, a3, f1_a, f2_a;
  reg [CW-1:0] f1_d, f2_d;
  wire [CW-1:0] dout_f = fb ? do1 : do0;
`ifdef BUG_HISTFWD
  wire [CW-1:0] cnt_old = dout_f;
`else
  wire [CW-1:0] cnt_old = (f1_v && f1_a == a3) ? f1_d : (f2_v && f2_a == a3) ? f2_d : dout_f;
`endif
  wire [CW-1:0] cnt_new = cnt_old + 1'b1;
  wire          f_we = v3 && (fst == F_IN || fst == F_DRAIN);

  reg [RKW-1:0] ncnt;
  reg [7:0]     nq_c;
  reg [6:0]     nr_c;
  reg [RKW-1:0] bnm1 [0:1];
  reg [7:0]     bnq  [0:1];
  reg [6:0]     bnr  [0:1];
  reg signed [W-1:0] boff [0:1];
  reg [SHW-1:0] bsh  [0:1];

  reg [BW:0]    rd_b;
  reg           rv1, rv2;
  reg [CW-1:0]  hq [0:3];
  reg [1:0]     hq_rp, hq_wp;
  reg [2:0]     hq_n;
  wire          hv = (hq_n != 3'd0);
  wire [CW-1:0] h = hq[hq_rp];
  wire          issue = scanning && !rd_b[BW] && ({1'b0, hq_n} + rv1 + rv2 < 4'd4);
  wire [CW-1:0] dout_s = sb ? do1 : do0;
  reg  [BW-1:0] b;
  reg  [CW-1:0] cprev;
  wire [CW:0]   cend = {1'b0, cprev} + {1'b0, h};

  reg signed [W-1:0] s_off;
  reg [SHW-1:0] s_sh;
  reg [RKW-1:0] s_nm1;
  reg [7:0]     s_nq;
  reg [6:0]     s_nr;
  reg           s_buf;

  reg [6:0]     gk, gr;
  reg [RKW-1:0] gi0, glast;
  reg           gph, gfirst, gdone;
  wire [RKW-1:0] gi1 = (gi0 < s_nm1) ? gi0 + 1'b1 : s_nm1;
  wire [RKW-1:0] gc = gph ? gi1 : gi0;
  wire           gemit = gfirst | (gc > glast);
  wire           rq_v = scanning & ~gdone & gemit;
  wire           in_bin = ({1'b0, {(CW-RKW){1'b0}}, gc} < cend);
  reg  [4:0]     occ;
  wire           resolve = scanning & hv & rq_v & in_bin & (occ < 5'd16);
  wire           s_pop = scanning & hv & (gdone | (rq_v & ~in_bin));
  wire           skip = scanning & ~gdone & ~gemit;
  wire           gadv = resolve | skip;
  wire [7:0]     gsum = {1'b0, gr} + {1'b0, s_nr};
  wire           gcar = (gsum >= 8'd100);

  reg [6:0]     ak, ar;
  reg [RKW-1:0] ai0, last_rk;
  reg           abusy, have_last;
  reg signed [VW-1:0] last_v, prev_v;
  wire           sstart = ~scanning & ~abusy & (fst != F_CLR) & ((sb ? bst1 : bst0) == B_FULL);

  always @(*) begin
    we0 = 1'b0; wa0 = a3; wd0 = cnt_new; ra0 = a1;
    we1 = 1'b0; wa1 = a3; wd1 = cnt_new; ra1 = a1;
    if (fst == F_CLR) begin
      we0 = 1'b1; wa0 = clr_a; wd0 = {CW{1'b0}};
      we1 = 1'b1; wa1 = clr_a; wd1 = {CW{1'b0}};
    end else begin
      if (fb) we1 = f_we; else we0 = f_we;
      if (scanning && !sb) begin we0 = s_pop; wa0 = b; wd0 = {CW{1'b0}}; ra0 = rd_b[BW-1:0]; end
      if (scanning && sb)  begin we1 = s_pop; wa1 = b; wd1 = {CW{1'b0}}; ra1 = rd_b[BW-1:0]; end
    end
  end

  reg wv [0:F];
  reg [DW-1:0] wrem [0:F];
  reg [DW-1:0] wden [0:F];
  reg [F-1:0]  wq   [0:F];
  reg signed [EW-1:0] wedge [0:F];
  reg [SHW-1:0] wsh [0:F];
  reg [RKW-1:0] wrk [0:F];

  reg [3:0]  vf_wp, vf_rp;
  reg [4:0]  vf_n;
  reg [RKW-1:0] vf_rkm [0:15];
  reg signed [VW-1:0] vf_vm [0:15];
  wire vf_ne = (vf_n != 5'd0);
  wire [RKW-1:0] vf_rk = vf_rkm[vf_rp];
  wire signed [VW-1:0] vf_v = vf_vm[vf_rp];
  wire signed [VW-1:0] wval = ($signed({{(VW-EW){wedge[F][EW-1]}}, wedge[F]}) <<< F) + $signed({{(VW-F){1'b0}}, wq[F]} << wsh[F]);

  wire [RKW-1:0] ai1 = (ai0 < s_nm1) ? ai0 + 1'b1 : s_nm1;
  wire           need = ~have_last | (last_rk < ai1);
  wire           apop = abusy & need & vf_ne;
  wire [RKW-1:0] nl_rk = apop ? vf_rk : last_rk;
  wire signed [VW-1:0] nl_v = apop ? vf_v : last_v;
  wire signed [VW-1:0] np_v = apop ? last_v : prev_v;
  wire           nhave = have_last | apop;
  wire           aemit = abusy & nhave & (nl_rk >= ai1);
  wire signed [VW-1:0] e_v0 = (ai0 == ai1) ? nl_v : np_v;
  wire [7:0]     asum = {1'b0, ar} + {1'b0, s_nr};
  wire           acar = (asum >= 8'd100);

  wire [RKW-1:0] jrel = gc - cprev[RKW-1:0];

  always @(posedge clk) begin
    if (rst) begin
      fst <= F_CLR;
      clr_a <= {BW{1'b0}};
      bst0 <= B_EMPTY;
      bst1 <= B_EMPTY;
      wdn <= 2'b00;
      odn <= 2'b00;
      fb <= 1'b0;
      sb <= 1'b0;
      scanning <= 1'b0;
      abusy <= 1'b0;
      v1 <= 1'b0;
      v2 <= 1'b0;
      v3 <= 1'b0;
      f1_v <= 1'b0;
      f2_v <= 1'b0;
      rv1 <= 1'b0;
      rv2 <= 1'b0;
      ncnt <= {RKW{1'b0}};
      nq_c <= 8'd0;
      nr_c <= 7'd0;
      occ <= 5'd0;
      vf_wp <= 4'd0;
      vf_rp <= 4'd0;
      vf_n <= 5'd0;
    end else begin
      v1 <= accept;
      a1 <= bin_in;
      v2 <= v1;
      a2 <= a1;
      v3 <= v2;
      a3 <= a2;
      f1_v <= f_we;
      f1_a <= a3;
      f1_d <= cnt_new;
      f2_v <= f1_v;
      f2_a <= f1_a;
      f2_d <= f1_d;
      case (fst)
        F_CLR: begin
          clr_a <= clr_a + 1'b1;
          if (clr_a == NB - 1) fst <= F_WAIT;
        end
        F_WAIT: if ((fb ? bst1 : bst0) == B_EMPTY) fst <= F_IN;
        F_IN: if (accept) begin
          if (in_last) begin
            bnm1[fb] <= ncnt;
            bnq[fb] <= nq_c;
            bnr[fb] <= nr_c;
            boff[fb] <= cfg_offset;
            bsh[fb] <= cfg_shift;
            ncnt <= {RKW{1'b0}};
            nq_c <= 8'd0;
            nr_c <= 7'd0;
            fst <= F_DRAIN;
          end else begin
            ncnt <= ncnt + 1'b1;
            if (nr_c == 7'd99) begin nr_c <= 7'd0; nq_c <= nq_c + 1'b1; end
            else nr_c <= nr_c + 1'b1;
          end
        end
        F_DRAIN: if (!v1 && !v2 && !v3) begin
          if (fb) bst1 <= B_FULL; else bst0 <= B_FULL;
          fb <= ~fb;
          fst <= F_WAIT;
        end
        default: fst <= F_CLR;
      endcase

      rv1 <= issue;
      rv2 <= rv1;
      if (rv2) begin
        hq[hq_wp] <= dout_s;
        hq_wp <= hq_wp + 1'b1;
      end
      if (s_pop) hq_rp <= hq_rp + 1'b1;
      hq_n <= hq_n + rv2 - s_pop;
      if (issue) rd_b <= rd_b + 1'b1;

      if (sstart) begin
        scanning <= 1'b1;
        if (sb) bst1 <= B_SCAN; else bst0 <= B_SCAN;
        s_off <= boff[sb];
        s_sh <= bsh[sb];
        s_nm1 <= bnm1[sb];
        s_nq <= bnq[sb];
        s_nr <= bnr[sb];
        s_buf <= sb;
        wdn[sb] <= 1'b0;
        odn[sb] <= 1'b0;
        rd_b <= {(BW+1){1'b0}};
        hq_rp <= 2'd0;
        hq_wp <= 2'd0;
        hq_n <= 3'd0;
        b <= {BW{1'b0}};
        cprev <= {CW{1'b0}};
        gk <= 7'd0;
        gr <= 7'd0;
        gi0 <= {RKW{1'b0}};
        gph <= 1'b0;
        gfirst <= 1'b1;
        gdone <= 1'b0;
        abusy <= 1'b1;
        ak <= 7'd0;
        ar <= 7'd0;
        ai0 <= {RKW{1'b0}};
        have_last <= 1'b0;
      end else begin
        if (s_pop) begin
          cprev <= cend[CW-1:0];
          b <= b + 1'b1;
          if (b == NB - 1) begin
            scanning <= 1'b0;
            sb <= ~sb;
            if (odn[s_buf] || (out_valid && out_last && out_buf == s_buf)) begin
              if (s_buf) bst1 <= B_EMPTY; else bst0 <= B_EMPTY;
            end else wdn[s_buf] <= 1'b1;
          end
        end
        if (resolve) begin
          glast <= gc;
          gfirst <= 1'b0;
        end
        if (gadv) begin
          if (!gph) gph <= 1'b1;
          else begin
            gph <= 1'b0;
            gk <= gk + 1'b1;
            gr <= gcar ? gsum - 8'd100 : gsum[6:0];
            gi0 <= gi0 + s_nq + gcar;
            if (gk == 7'd100) gdone <= 1'b1;
          end
        end
        if (apop) begin
          last_rk <= vf_rk;
          last_v <= vf_v;
          prev_v <= last_v;
          have_last <= 1'b1;
        end
        if (aemit) begin
          ak <= ak + 1'b1;
          ar <= acar ? asum - 8'd100 : asum[6:0];
          ai0 <= ai0 + s_nq + acar;
          if (ak == 7'd100) abusy <= 1'b0;
        end
      end

      if (out_valid && out_last) begin
        if (wdn[out_buf]) begin
          if (out_buf) bst1 <= B_EMPTY; else bst0 <= B_EMPTY;
        end else if (!(s_pop && b == NB - 1 && s_buf == out_buf)) odn[out_buf] <= 1'b1;
      end

      occ <= occ + resolve - apop;
      if (wv[F]) begin
        vf_rkm[vf_wp] <= wrk[F];
        vf_vm[vf_wp] <= wval;
        vf_wp <= vf_wp + 1'b1;
      end
      if (apop) vf_rp <= vf_rp + 1'b1;
      vf_n <= vf_n + wv[F] - apop;
    end
  end

  integer i;
  reg [DW:0] rem2;
  always @(posedge clk) begin
    if (rst) begin
      for (i = 0; i <= F; i = i + 1) wv[i] <= 1'b0;
    end else begin
      wv[0] <= resolve;
      for (i = 0; i < F; i = i + 1) wv[i+1] <= wv[i];
    end
`ifdef BUG_OSMID
    wrem[0] <= {jrel, 1'b0};
`else
    wrem[0] <= {jrel, 1'b1};
`endif
    wden[0] <= {h, 1'b0};
    wq[0] <= {F{1'b0}};
    wedge[0] <= $signed({{(EW-W){s_off[W-1]}}, s_off}) + $signed({{(EW-BW){1'b0}}, b} << s_sh);
    wsh[0] <= s_sh;
    wrk[0] <= gc;
    for (i = 0; i < F; i = i + 1) begin
      rem2 = {wrem[i], 1'b0};
      if (rem2 >= {1'b0, wden[i]}) begin
        wrem[i+1] <= rem2 - {1'b0, wden[i]};
        wq[i+1] <= {wq[i][F-2:0], 1'b1};
      end else begin
        wrem[i+1] <= rem2[DW-1:0];
        wq[i+1] <= {wq[i][F-2:0], 1'b0};
      end
      wden[i+1] <= wden[i];
      wedge[i+1] <= wedge[i];
      wsh[i+1] <= wsh[i];
      wrk[i+1] <= wrk[i];
    end
  end

  reg                 iv  [0:NI+1];
  reg                 il  [0:NI+1];
  reg [6:0]           ilv [0:NI+1];
  reg                 ib  [0:NI+1];
  reg signed [VW-1:0] iv0 [0:NI+1];
  reg [VW-1:0]        idf;
  reg [6:0]           irr;
  reg [PW-1:0]        idq [1:NI+1];
  reg [6:0]           idr [1:NI+1];

  integer j, t;
  reg [PW-1:0] tq_;
  reg [7:0]    tr_;
  always @(posedge clk) begin
    if (rst) begin
      for (j = 0; j <= NI + 1; j = j + 1) iv[j] <= 1'b0;
      out_valid <= 1'b0;
    end else begin
      iv[0] <= aemit;
      for (j = 0; j <= NI; j = j + 1) iv[j+1] <= iv[j];
      out_valid <= iv[NI+1];
    end
    il[0] <= (ak == 7'd100);
    ilv[0] <= ak;
    ib[0] <= s_buf;
    iv0[0] <= e_v0;
    idf <= nl_v - e_v0;
    irr <= ar;
    il[1] <= il[0];
    ilv[1] <= ilv[0];
    ib[1] <= ib[0];
    iv0[1] <= iv0[0];
    idq[1] <= idf * irr;
    idr[1] <= 7'd0;
    for (j = 1; j <= NI; j = j + 1) begin
      tq_ = idq[j];
      tr_ = {1'b0, idr[j]};
      for (t = 0; t < 4; t = t + 1) begin
        tr_ = {tr_[6:0], tq_[PW-1]};
        tq_ = {tq_[PW-2:0], 1'b0};
        if (tr_ >= 8'd100) begin
          tr_ = tr_ - 8'd100;
          tq_[0] = 1'b1;
        end
      end
      idq[j+1] <= tq_;
      idr[j+1] <= tr_[6:0];
      il[j+1] <= il[j];
      ilv[j+1] <= ilv[j];
      ib[j+1] <= ib[j];
      iv0[j+1] <= iv0[j];
    end
    out_last <= il[NI+1];
    out_level <= ilv[NI+1];
    out_buf <= ib[NI+1];
    out_data <= $signed({{(32-VW){iv0[NI+1][VW-1]}}, iv0[NI+1]}) + $signed({1'b0, idq[NI+1][30:0]});
  end
endmodule
`default_nettype wire
