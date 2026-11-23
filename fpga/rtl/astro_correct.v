`default_nettype none
module astro_correct #(
  parameter integer QW = 32
) (
  input  wire               clk,
  input  wire               rst,
  input  wire               claim,
  input  wire               commit,
  output wire               claim_ok,
  output reg  [1:0]         meas_bank,
  input  wire               b_valid,
  input  wire [6:0]         b_level,
  input  wire signed [QW:0] b_tq,
  input  wire signed [QW-1:0] b_qbar,
  input  wire [1:0]         b_bank,
  input  wire               b_fault,
  input  wire               c_valid,
  input  wire               c_last,
  input  wire signed [15:0] c_data,
  output wire               c_ready,
  output reg                co_valid,
  output reg  signed [15:0] co_data
);
  localparam integer ND = 16;
  localparam integer PE = 10 + ND;

  reg [3:0] busy, rdy;
  reg [1:0] corr_bank;
  assign claim_ok = ~busy[meas_bank];
  assign c_ready = rdy[corr_bank];
  wire c_acc = c_valid & c_ready;

  reg               o_rel;
  reg [1:0]         o_bank;

  always @(posedge clk) begin
    if (rst) begin
      busy <= 4'b0000;
      rdy <= 4'b0000;
      meas_bank <= 2'd0;
      corr_bank <= 2'd0;
    end else begin
      if (claim) busy[meas_bank] <= 1'b1;
      if (commit) meas_bank <= meas_bank + 1'b1;
      if (b_valid && b_level == 7'd100) rdy[b_bank] <= 1'b1;
      if (c_acc && c_last) begin
        rdy[corr_bank] <= 1'b0;
        corr_bank <= corr_bank + 1'b1;
      end
      if (o_rel) busy[o_bank] <= 1'b0;
    end
  end

  (* ram_style = "block" *) reg [QW:0] tqa [0:511];
  (* ram_style = "block" *) reg [QW:0] tqb [0:511];
  (* ram_style = "block" *) reg [QW-1:0] qam [0:511];
  (* ram_style = "block" *) reg [QW-1:0] qbm [0:511];
  (* ram_style = "distributed" *) reg [6:0] runm [0:511];
  reg [3:0]         byp;
  reg signed [QW+1:0] ct0 [0:3];
  reg signed [QW+1:0] ct1 [0:3];
  reg signed [QW:0] ptq;
  reg [6:0]         prun;
  wire [6:0] brun = (b_level != 7'd0 && b_tq == ptq) ? prun : b_level;
  wire [8:0] baddr = {b_bank, b_level};
  wire [8:0] bprev = {b_bank, b_level - 1'b1};
  wire signed [QW+1:0] bct = $signed({b_qbar[QW-1], b_qbar[QW-1], b_qbar}) - $signed({b_tq[QW], b_tq});

  wire signed [QW+1:0] tqc = $signed({b_tq[QW], b_tq}) + 65535;
  wire signed [QW-15:0] cl_raw = tqc[QW+1:16];
  wire signed [17:0] cl = (cl_raw < -32769) ? -18'sd32769 : (cl_raw > 32768) ? 18'sd32768 : cl_raw[17:0];
  wire [6:0] kp1 = b_level + 1'b1;
  reg  [2:0] tz;
  always @(*) begin
    casez (kp1)
      7'b??????1: tz = 3'd0;
      7'b?????10: tz = 3'd1;
      7'b????100: tz = 3'd2;
      7'b???1000: tz = 3'd3;
      7'b??10000: tz = 3'd4;
      7'b?100000: tz = 3'd5;
      default:    tz = 3'd6;
    endcase
  end

  always @(posedge clk) begin
    if (b_valid) begin
      tqa[baddr] <= b_tq;
      qam[baddr] <= b_qbar;
      runm[baddr] <= brun;
      ptq <= b_tq;
      prun <= brun;
      if (b_level == 7'd0) begin
        byp[b_bank] <= ~b_fault;
        ct0[b_bank] <= bct;
      end
      if (b_level == 7'd100) ct1[b_bank] <= bct;
    end
    if (b_valid && b_level != 7'd0) begin
      tqb[bprev] <= b_tq;
      qbm[bprev] <= b_qbar;
    end
  end

  reg               lv_v  [0:7];
  reg               lv_l  [0:7];
  reg [1:0]         lv_b  [0:7];
  reg signed [15:0] lv_x  [0:7];
  reg [6:0]         lv_i  [0:7];
  wire signed [17:0] lt_rd [0:6];

  genvar s;
  generate
    for (s = 0; s < 7; s = s + 1) begin : g_lt
      localparam integer B = 6 - s;
      localparam integer E = 1 << s;
      (* ram_style = "distributed" *) reg [17:0] lt [0:4*E-1];
      wire [8:0] wa = b_bank * E + (kp1 >> (B + 1));
      wire [8:0] ra = lv_b[s] * E + (lv_i[s] >> (B + 1));
      always @(posedge clk) if (b_valid && tz == B) lt[wa] <= cl;
      assign lt_rd[s] = lt[ra];
    end
  endgenerate

  integer i;
  always @(posedge clk) begin
    if (rst) begin
      for (i = 0; i <= 7; i = i + 1) lv_v[i] <= 1'b0;
    end else begin
      lv_v[0] <= c_acc;
      for (i = 0; i < 7; i = i + 1) lv_v[i+1] <= lv_v[i];
    end
    lv_l[0] <= c_last;
    lv_b[0] <= corr_bank;
    lv_x[0] <= c_data;
    lv_i[0] <= 7'd0;
    for (i = 0; i < 7; i = i + 1) begin
      lv_l[i+1] <= lv_l[i];
      lv_b[i+1] <= lv_b[i];
      lv_x[i+1] <= lv_x[i];
      if ((lv_i[i] + (7'd1 << (6 - i)) <= 7'd101) && (lt_rd[i] <= $signed({{2{lv_x[i][15]}}, lv_x[i]})))
        lv_i[i+1] <= lv_i[i] + (7'd1 << (6 - i));
      else
        lv_i[i+1] <= lv_i[i];
    end
  end

  wire below7 = (lv_i[7] == 7'd0);
  wire above7 = (lv_i[7] == 7'd101);
  wire [6:0] k7 = below7 ? 7'd0 : above7 ? 7'd100 : lv_i[7] - 1'b1;
  wire [8:0] ad7 = {lv_b[7], k7};

  reg [QW:0] tqr, tqr1, tqk8, tqk18;
  reg        p8_l, p8_be, p8_ab, pa_l, pa_be, pa_ab;
  reg [1:0]  p8_b, pa_b;
  reg signed [15:0] p8_x, pa_x;
  reg [6:0]  p8_k, p8_a, pa_k, pa_a;
  always @(posedge clk) begin
    tqr <= tqa[ad7];
    tqr1 <= tqb[ad7];
    pa_a <= runm[ad7];
    pa_l <= lv_l[7];
    pa_be <= below7;
    pa_ab <= above7;
    pa_b <= lv_b[7];
    pa_x <= lv_x[7];
    pa_k <= k7;
    tqk8 <= tqr;
    tqk18 <= tqr1;
    p8_a <= pa_a;
    p8_l <= pa_l;
    p8_be <= pa_be;
    p8_ab <= pa_ab;
    p8_b <= pa_b;
    p8_x <= pa_x;
    p8_k <= pa_k;
  end

  wire signed [QW+1:0] xf8 = $signed({{(QW-30){p8_x[15]}}, p8_x, 16'd0});
  wire signed [QW+1:0] r8 = xf8 - $signed({tqk8[QW], tqk8});
  wire signed [QW+1:0] dt8 = $signed({tqk18[QW], tqk18}) - $signed({tqk8[QW], tqk8});
  wire [7:0]  s8 = {1'b0, p8_a} + {1'b0, p8_k};
  wire        tie8 = (r8 == 0);
  wire        int8 = ~p8_be & ~p8_ab & ~tie8;

  reg               dv_v  [10:PE];
  reg               dv_l  [10:PE];
  reg [1:0]         dv_b  [10:PE];
  reg [2:0]         dv_kd [10:PE];
  reg signed [15:0] dv_x  [10:PE];
  reg [6:0]         dv_j  [10:PE];
  reg [16:0]        dv_tf [10:PE];
  reg [QW+2:0]      dv_r  [10:PE];
  reg [QW+1:0]      dv_d  [10:PE];
  reg [ND-1:0]      dv_q  [10:PE];

  reg               pa_v, p9_v;
  always @(posedge clk) begin
    if (rst) begin
      pa_v <= 1'b0;
      p9_v <= 1'b0;
    end else begin
      pa_v <= lv_v[7];
      p9_v <= pa_v;
    end
  end

  wire [2:0] kd8 = p8_be ? 3'd1 : tie8 ? 3'd3 : p8_ab ? 3'd2 : 3'd0;

  integer j;
  reg [QW+3:0] rr2;
  always @(posedge clk) begin
    if (rst) begin
      for (j = 10; j <= PE; j = j + 1) dv_v[j] <= 1'b0;
    end else begin
      dv_v[10] <= p9_v;
      for (j = 10; j < PE; j = j + 1) dv_v[j+1] <= dv_v[j];
    end
    dv_l[10] <= p8_l;
    dv_b[10] <= p8_b;
    dv_kd[10] <= kd8;
    dv_x[10] <= p8_x;
    dv_j[10] <= tie8 ? ((s8[7:1] > 7'd99) ? 7'd99 : s8[7:1]) : p8_k;
    dv_tf[10] <= (s8[7:1] > 7'd99) ? 17'd65536 : {1'b0, s8[0], 15'd0};
    dv_r[10] <= int8 ? {1'b0, r8} : {(QW+3){1'b0}};
    dv_d[10] <= (dt8 == 0) ? {{(QW+1){1'b0}}, 1'b1} : dt8;
    dv_q[10] <= {ND{1'b0}};
    for (j = 10; j < PE; j = j + 1) begin
      rr2 = {dv_r[j], 1'b0};
      if (rr2 >= {2'b0, dv_d[j]}) begin
        dv_r[j+1] <= rr2 - {2'b0, dv_d[j]};
        dv_q[j+1] <= {dv_q[j][ND-2:0], 1'b1};
      end else begin
        dv_r[j+1] <= rr2[QW+2:0];
        dv_q[j+1] <= {dv_q[j][ND-2:0], 1'b0};
      end
      dv_d[j+1] <= dv_d[j];
      dv_l[j+1] <= dv_l[j];
      dv_b[j+1] <= dv_b[j];
      dv_kd[j+1] <= dv_kd[j];
      dv_x[j+1] <= dv_x[j];
      dv_j[j+1] <= dv_j[j];
      dv_tf[j+1] <= dv_tf[j];
    end
  end

  wire [8:0] ja = {dv_b[PE], dv_j[PE]};
  wire [16:0] fr26 = (dv_kd[PE] == 3'd0) ? {1'b0, dv_q[PE]} : dv_tf[PE];

  reg               m_v [26:31];
  reg               m_l [26:31];
  reg [1:0]         m_b [26:31];
  reg [2:0]         m_kd [26:31];
  reg signed [15:0] m_x [26:31];
  reg [16:0]        m_fr26, m_fr27;
  reg signed [QW-1:0] qa26, qb26, qa27, qb27;
  reg signed [QW-1:0] qa [28:30];
  reg signed [QW:0] dq28;
  reg [16:0]        fr28;
  (* use_dsp = "yes" *) reg signed [QW+18:0] mp29;
  reg signed [QW+18:0] mp30;
  reg signed [QW+3:0] y31;

  wire signed [QW+18:0] mr30 = mp30 + 32768;
  wire signed [QW+3:0] xf30 = $signed({{(QW-28){m_x[30][15]}}, m_x[30], 16'd0});
  wire signed [QW+3:0] y31r = y31 + 32768;
  wire signed [QW-13:0] y16 = y31r[QW+3:16];

  always @(posedge clk) begin
    if (rst) begin
      for (j = 26; j <= 31; j = j + 1) m_v[j] <= 1'b0;
      co_valid <= 1'b0;
      o_rel <= 1'b0;
    end else begin
      m_v[26] <= dv_v[PE];
      for (j = 26; j < 31; j = j + 1) m_v[j+1] <= m_v[j];
      co_valid <= m_v[31];
      o_rel <= m_v[31] & m_l[31];
    end
    m_l[26] <= dv_l[PE];
    m_b[26] <= dv_b[PE];
    m_kd[26] <= dv_kd[PE];
    m_x[26] <= dv_x[PE];
    for (j = 26; j < 31; j = j + 1) begin
      m_l[j+1] <= m_l[j];
      m_b[j+1] <= m_b[j];
      m_kd[j+1] <= m_kd[j];
      m_x[j+1] <= m_x[j];
    end
    qa26 <= qam[ja];
    qb26 <= qbm[ja];
    m_fr26 <= fr26;
    qa27 <= qa26;
    qb27 <= qb26;
    m_fr27 <= m_fr26;
    qa[28] <= qa27;
    dq28 <= $signed({qb27[QW-1], qb27}) - $signed({qa27[QW-1], qa27});
    fr28 <= m_fr27;
    qa[29] <= qa[28];
    mp29 <= dq28 * $signed({1'b0, fr28});
    qa[30] <= qa[29];
    mp30 <= mp29;
    if (m_kd[30] == 3'd1)
      y31 <= xf30 + $signed({{2{ct0[m_b[30]][QW+1]}}, ct0[m_b[30]]});
    else if (m_kd[30] == 3'd2)
      y31 <= xf30 + $signed({{2{ct1[m_b[30]][QW+1]}}, ct1[m_b[30]]});
    else
      y31 <= $signed({{4{qa[30][QW-1]}}, qa[30]}) + $signed(mr30[QW+18:16]);
    o_bank <= m_b[31];
    if (byp[m_b[31]])
      co_data <= m_x[31];
    else
      co_data <= (y16 > 32767) ? 16'sh7FFF : (y16 < -32768) ? 16'sh8000 : y16[15:0];
  end
endmodule
`default_nettype wire
