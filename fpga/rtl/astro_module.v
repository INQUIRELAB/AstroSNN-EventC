`default_nettype none
module astro_module #(
  parameter integer L = 6,
  parameter integer QW = 32
) (
  input  wire              clk,
  input  wire              rst,
  input  wire              fault_flag,
  input  wire [15:0]       cfg_nbase,
  input  wire [17:0]       cfg_eta_fast,
  input  wire [17:0]       cfg_eta_slow,
  input  wire [L-1:0]      w_valid,
  input  wire [L-1:0]      w_last,
  input  wire [16*L-1:0]   w_data,
  output wire [L-1:0]      w_ready,
  input  wire [L-1:0]      m_valid,
  input  wire [L-1:0]      m_last,
  input  wire [16*L-1:0]   m_data,
  input  wire [5*L-1:0]    m_slot,
  input  wire [4*L-1:0]    m_t,
  output wire [L-1:0]      m_ready,
  input  wire [L-1:0]      c_valid,
  input  wire [L-1:0]      c_last,
  input  wire [16*L-1:0]   c_data,
  output wire [L-1:0]      c_ready,
  output wire [L-1:0]      co_valid,
  output wire [16*L-1:0]   co_data,
  input  wire              ws_en,
  input  wire              ws_we,
  input  wire              ws_sel,
  input  wire [2:0]        ws_lane,
  input  wire [11:0]       ws_addr,
  input  wire [2*QW-1:0]   ws_wdata,
  output reg               ws_rvalid,
  output reg  [2*QW-1:0]   ws_rdata,
  input  wire [11:0]       px_thd_on,
  input  wire [11:0]       px_thd_off,
  input  wire [11:0]       px_thh_on,
  input  wire [11:0]       px_thh_off,
  input  wire [4:0]        px_dwell,
  input  wire              px_in_valid,
  input  wire [127:0]      px_in_data,
  output wire              px_in_ready,
  output wire              px_out_valid,
  output wire [127:0]      px_out_data,
  output wire [7:0]        px_out_flags,
  output wire              px_out_last
);
  wire [2*QW*L-1:0] h_rdata;

  genvar g;
  generate
    for (g = 0; g < L; g = g + 1) begin : g_lane
      astro_lane #(.QW(QW)) u_lane (
        .clk(clk), .rst(rst), .fault_flag(fault_flag), .cfg_nbase(cfg_nbase),
        .cfg_eta_fast(cfg_eta_fast), .cfg_eta_slow(cfg_eta_slow),
        .w_valid(w_valid[g]), .w_last(w_last[g]), .w_data(w_data[16*g +: 16]), .w_ready(w_ready[g]),
        .m_valid(m_valid[g]), .m_last(m_last[g]), .m_data(m_data[16*g +: 16]), .m_slot(m_slot[5*g +: 5]),
        .m_t(m_t[4*g +: 4]), .m_ready(m_ready[g]),
        .c_valid(c_valid[g]), .c_last(c_last[g]), .c_data(c_data[16*g +: 16]), .c_ready(c_ready[g]),
        .co_valid(co_valid[g]), .co_data(co_data[16*g +: 16]),
        .h_en(ws_en && (ws_lane == g)), .h_we(ws_we), .h_sel(ws_sel), .h_addr(ws_addr), .h_wdata(ws_wdata),
        .h_rdata(h_rdata[2*QW*g +: 2*QW]));
    end
  endgenerate

  reg [2:0] hl1, hl2, hl3;
  reg       hr1, hr2, hr3;
  always @(posedge clk) begin
    if (rst) begin
      hr1 <= 1'b0;
      hr2 <= 1'b0;
      hr3 <= 1'b0;
      ws_rvalid <= 1'b0;
    end else begin
      hr1 <= ws_en & ~ws_we;
      hr2 <= hr1;
      hr3 <= hr2;
      ws_rvalid <= hr3;
    end
    hl1 <= ws_lane;
    hl2 <= hl1;
    hl3 <= hl2;
    ws_rdata <= h_rdata[2*QW*hl3 +: 2*QW];
  end

  astro_pixrep u_px (
    .clk(clk), .rst(rst), .cfg_thd_on(px_thd_on), .cfg_thd_off(px_thd_off), .cfg_thh_on(px_thh_on), .cfg_thh_off(px_thh_off), .cfg_dwell(px_dwell),
    .in_valid(px_in_valid), .in_data(px_in_data), .in_ready(px_in_ready),
    .out_valid(px_out_valid), .out_data(px_out_data), .out_flags(px_out_flags), .out_last(px_out_last));
endmodule
`default_nettype wire
