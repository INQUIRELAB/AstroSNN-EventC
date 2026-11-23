`default_nettype none
module astro_lane #(
  parameter integer QW = 32
) (
  input  wire               clk,
  input  wire               rst,
  input  wire               fault_flag,
  input  wire [15:0]        cfg_nbase,
  input  wire [17:0]        cfg_eta_fast,
  input  wire [17:0]        cfg_eta_slow,
  input  wire               w_valid,
  input  wire               w_last,
  input  wire signed [15:0] w_data,
  output wire               w_ready,
  input  wire               m_valid,
  input  wire               m_last,
  input  wire signed [15:0] m_data,
  input  wire [4:0]         m_slot,
  input  wire [3:0]         m_t,
  output wire               m_ready,
  input  wire               c_valid,
  input  wire               c_last,
  input  wire signed [15:0] c_data,
  output wire               c_ready,
  output wire               co_valid,
  output wire signed [15:0] co_data,
  input  wire               h_en,
  input  wire               h_we,
  input  wire               h_sel,
  input  wire [11:0]        h_addr,
  input  wire [2*QW-1:0]   h_wdata,
  output wire [2*QW-1:0]   h_rdata
);
  reg  in_frame;
  wire claim_ok, q_ready, win_ne, fill_buf;
  wire [1:0] meas_bank;
  wire signed [15:0] win_off;
  wire [2:0] win_sh;
  wire go = in_frame | (claim_ok & win_ne);
  assign m_ready = q_ready & go;
  wire acc = m_valid & m_ready;
  wire start = acc & ~in_frame;
  wire commit = acc & m_last;

  always @(posedge clk) begin
    if (rst) in_frame <= 1'b0;
    else if (commit) in_frame <= 1'b0;
    else if (start) in_frame <= 1'b1;
  end

  astro_window u_w (
    .clk(clk), .rst(rst), .w_valid(w_valid), .w_last(w_last), .w_data(w_data), .w_ready(w_ready),
    .pop(commit), .ne(win_ne), .off(win_off), .sh(win_sh));

  wire               q_valid, q_lastl, q_buf;
  wire [6:0]         q_level;
  wire signed [31:0] q_data;

  astro_quantile u_q (
    .clk(clk), .rst(rst), .cfg_offset(win_off), .cfg_shift(win_sh),
    .in_valid(m_valid & go), .in_last(m_last), .in_data(m_data), .in_ready(q_ready), .fill_buf(fill_buf),
    .out_valid(q_valid), .out_last(q_lastl), .out_level(q_level), .out_data(q_data), .out_buf(q_buf));

  wire               b_valid, b_fault;
  wire [1:0]         b_bank;
  wire [6:0]         b_level;
  wire signed [QW:0] b_tq;
  wire signed [QW-1:0] b_qbar;

  astro_update #(.QW(QW)) u_upd (
    .clk(clk), .rst(rst), .cfg_eta_fast(cfg_eta_fast), .cfg_eta_slow(cfg_eta_slow),
    .st_start(start), .st_buf(fill_buf), .st_slot(m_slot), .st_t(m_t), .st_fault(fault_flag), .st_nbase(cfg_nbase),
    .st_bank(meas_bank),
    .q_valid(q_valid), .q_buf(q_buf), .q_level(q_level), .q_data(q_data),
    .b_valid(b_valid), .b_level(b_level), .b_tq(b_tq), .b_qbar(b_qbar), .b_bank(b_bank), .b_fault(b_fault),
    .h_en(h_en), .h_we(h_we), .h_sel(h_sel), .h_addr(h_addr), .h_wdata(h_wdata), .h_rdata(h_rdata));

  astro_correct #(.QW(QW)) u_cor (
    .clk(clk), .rst(rst), .claim(start), .commit(commit), .claim_ok(claim_ok), .meas_bank(meas_bank),
    .b_valid(b_valid), .b_level(b_level), .b_tq(b_tq), .b_qbar(b_qbar), .b_bank(b_bank), .b_fault(b_fault),
    .c_valid(c_valid), .c_last(c_last), .c_data(c_data), .c_ready(c_ready),
    .co_valid(co_valid), .co_data(co_data));
endmodule
`default_nettype wire
