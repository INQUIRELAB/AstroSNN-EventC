`timescale 1ns/1ps
`default_nettype none
module c2_core #(
  parameter integer QW = 32,
  parameter integer L = 6
) (
  input wire clk,
  input wire rstn,
  input wire [31:0] usr_access,
  input wire [11:0] s_awaddr,
  input wire s_awvalid,
  output wire s_awready,
  input wire [31:0] s_wdata,
  input wire [3:0] s_wstrb,
  input wire s_wvalid,
  output wire s_wready,
  output reg [1:0] s_bresp = 2'b00,
  output reg s_bvalid = 1'b0,
  input wire s_bready,
  input wire [11:0] s_araddr,
  input wire s_arvalid,
  output wire s_arready,
  output reg [31:0] s_rdata = 32'd0,
  output reg [1:0] s_rresp = 2'b00,
  output reg s_rvalid = 1'b0,
  input wire s_rready,
  output wire m_arvalid,
  input wire m_arready,
  output wire [31:0] m_araddr,
  output wire [7:0] m_arlen,
  input wire m_rvalid,
  input wire [127:0] m_rdata,
  input wire [1:0] m_rresp,
  input wire m_rlast,
  output wire m_rready,
  output wire m_awvalid,
  input wire m_awready,
  output wire [31:0] m_awaddr,
  output wire [7:0] m_awlen,
  output wire m_wvalid,
  input wire m_wready,
  output wire [127:0] m_wdata,
  output wire [15:0] m_wstrb,
  output wire m_wlast,
  input wire m_bvalid,
  input wire [1:0] m_bresp,
  output wire m_bready
);
  localparam [31:0] ID_WORD = 32'hC2DA0001;
  reg sys_rst = 1'b1;
  always @(posedge clk) sys_rst <= !rstn;

  reg enable = 1'b0, abort = 1'b0, err = 1'b0, done_s = 1'b0, refused = 1'b0, tmo = 1'b0;
  reg [3:0] ecode = 4'd0;
  reg [31:0] eaddr = 32'd0, einfo = 32'd0;
  reg [31:0] base = 32'd0, limit = 32'd0, daddr = 32'd0, tmo_lim = 32'h01000000;
  reg [23:0] dcount = 24'd0;
  reg [31:0] p1 = 32'd0, p2 = 32'd0, p3 = 32'd0;
  reg [31:0] cyc = 32'd0, rbeats = 32'd0, wbeats = 32'd0, wd = 32'd0;
  reg [2:0] srst_cnt = 3'd0;
  wire srst = srst_cnt != 3'd0;
  wire urst = sys_rst || srst;
  reg start_p = 1'b0;
  wire go = enable && !abort && !err && !srst;
  wire [32:0] lim_end = {1'b0, base} + {1'b0, limit};

  wire rd_idle, wr_idle;
  wire [5:0] rd_out, wr_out;
`ifdef BUG_ABORT_IDLE
  wire idle = wr_idle;
`else
  wire idle = rd_idle && wr_idle;
`endif
  wire busy;
  wire [23:0] ddone;
  wire t_idle;
  wire [5:0] lane_idle;
  wire busy_any = busy || !t_idle || !(&lane_idle);

  wire aw_go = s_awvalid && s_wvalid && !s_bvalid;
  assign s_awready = aw_go;
  assign s_wready = aw_go;
  assign s_arready = s_arvalid && !s_rvalid;
  wire [9:0] wi = s_awaddr[11:2];
  wire [9:0] ri = s_araddr[11:2];

  wire seq_err_v, rd_err_v, wr_err_v, tile_err_v;
  wire [3:0] seq_err_c, rd_err_c, wr_err_c, tile_err_c;
  wire [31:0] seq_err_i, rd_err_a, wr_err_a;
  wire seq_done;

  always @(posedge clk) begin
    start_p <= 1'b0;
    if (srst_cnt != 3'd0) srst_cnt <= srst_cnt - 1'b1;
    if (sys_rst) begin
      enable <= 1'b0; abort <= 1'b0; err <= 1'b0; done_s <= 1'b0; refused <= 1'b0; tmo <= 1'b0; ecode <= 4'd0;
      base <= 32'd0; limit <= 32'd0; daddr <= 32'd0; dcount <= 24'd0; tmo_lim <= 32'h01000000;
      p1 <= 32'd0; p2 <= 32'd0; p3 <= 32'd0; s_bvalid <= 1'b0; s_rvalid <= 1'b0; srst_cnt <= 3'd0;
      cyc <= 32'd0; rbeats <= 32'd0; wbeats <= 32'd0; wd <= 32'd0;
    end else begin
      if (s_bvalid && s_bready) s_bvalid <= 1'b0;
      if (aw_go) begin
        s_bvalid <= 1'b1; s_bresp <= 2'b00;
        case (wi)
          10'h002: begin
            enable <= s_wdata[0];
            abort <= s_wdata[2];
            if (s_wdata[1] && s_wdata[0] && !busy && !err && !s_wdata[2]) begin start_p <= 1'b1; done_s <= 1'b0; cyc <= 32'd0; rbeats <= 32'd0; wbeats <= 32'd0; end
            if (s_wdata[3]) begin
              if (idle && (abort || !busy_any)) srst_cnt <= 3'd7;
              else refused <= 1'b1;
            end
            if (s_wdata[4] && idle) begin err <= 1'b0; tmo <= 1'b0; ecode <= 4'd0; refused <= 1'b0; end
          end
          10'h004: base <= s_wdata;
          10'h005: limit <= s_wdata;
          10'h006: daddr <= s_wdata;
          10'h007: dcount <= s_wdata[23:0];
          10'h008: tmo_lim <= s_wdata;
          10'h009: p1 <= s_wdata;
          10'h00a: p2 <= s_wdata;
          10'h00b: p3 <= s_wdata;
          default: s_bresp <= 2'b00;
        endcase
      end
      if (s_rvalid && s_rready) s_rvalid <= 1'b0;
      if (s_arvalid && !s_rvalid) begin
        s_rvalid <= 1'b1; s_rresp <= 2'b00;
        case (ri)
          10'h000: s_rdata <= ID_WORD;
          10'h001: s_rdata <= usr_access;
          10'h002: s_rdata <= {27'd0, 1'b0, 1'b0, abort, 1'b0, enable};
          10'h003: s_rdata <= {18'd0, enable, tmo, ecode, 2'd0, refused, abort, err, done_s, busy_any, idle};
          10'h004: s_rdata <= base;
          10'h005: s_rdata <= limit;
          10'h006: s_rdata <= daddr;
          10'h007: s_rdata <= {8'd0, dcount};
          10'h008: s_rdata <= tmo_lim;
          10'h009: s_rdata <= p1;
          10'h00a: s_rdata <= p2;
          10'h00b: s_rdata <= p3;
          10'h00c: s_rdata <= eaddr;
          10'h00d: s_rdata <= einfo;
          10'h00e: s_rdata <= {8'd0, ddone};
          10'h00f: s_rdata <= cyc;
          10'h010: s_rdata <= rbeats;
          10'h011: s_rdata <= wbeats;
          10'h012: s_rdata <= {10'd0, wr_out, 10'd0, rd_out};
          default: s_rdata <= 32'd0;
        endcase
      end
      if (busy) cyc <= cyc + 1'b1;
      if (m_rvalid) rbeats <= rbeats + 1'b1;
      if (m_wvalid && m_wready) wbeats <= wbeats + 1'b1;
      if (seq_done) done_s <= 1'b1;
      if (!err) begin
        if (rd_err_v) begin err <= 1'b1; ecode <= rd_err_c; eaddr <= rd_err_a; end
        else if (wr_err_v) begin err <= 1'b1; ecode <= wr_err_c; eaddr <= wr_err_a; end
        else if (seq_err_v) begin err <= 1'b1; ecode <= seq_err_c; einfo <= seq_err_i; end
        else if (tile_err_v) begin err <= 1'b1; ecode <= tile_err_c; end
        else if (tmo_lim != 32'd0 && wd >= tmo_lim) begin err <= 1'b1; tmo <= 1'b1; ecode <= 4'd7; end
      end
      if (!idle && !(m_arvalid && m_arready) && !m_rvalid && !(m_awvalid && m_awready) && !(m_wvalid && m_wready) && !m_bvalid)
        wd <= wd + 1'b1;
      else wd <= 32'd0;
    end
  end

  wire [8:0] rq_v, rq_g, rd_v;
  wire [32*9-1:0] rq_a;
  wire [5*9-1:0] rq_n;
  wire [127:0] rd_d;
  c2_rd #(.NR(9)) u_rd (.clk(clk), .rst(urst), .go(go), .base(base), .lim_end(lim_end),
    .rq_v(rq_v), .rq_a(rq_a), .rq_n(rq_n), .rq_g(rq_g), .rd_v(rd_v), .rd_d(rd_d),
    .err_v(rd_err_v), .err_code(rd_err_c), .err_addr(rd_err_a), .idle(rd_idle), .outstanding(rd_out),
    .arvalid(m_arvalid), .arready(m_arready), .araddr(m_araddr), .arlen(m_arlen),
    .rvalid(m_rvalid), .rdata(m_rdata), .rresp(m_rresp), .rlast(m_rlast), .rready(m_rready));

  wire [7:0] wq_v, wq_g, wd_pop;
  wire [32*8-1:0] wq_a;
  wire [5*8-1:0] wq_n;
  wire [128*8-1:0] wd_d;
  wire [16*8-1:0] wd_s;
  c2_wr #(.NW(8)) u_wr (.clk(clk), .rst(urst), .go(go), .base(base), .lim_end(lim_end),
    .wq_v(wq_v), .wq_a(wq_a), .wq_n(wq_n), .wq_g(wq_g), .wd_d(wd_d), .wd_s(wd_s), .wd_pop(wd_pop),
    .err_v(wr_err_v), .err_code(wr_err_c), .err_addr(wr_err_a), .idle(wr_idle), .outstanding(wr_out),
    .awvalid(m_awvalid), .awready(m_awready), .awaddr(m_awaddr), .awlen(m_awlen),
    .wvalid(m_wvalid), .wready(m_wready), .wdata(m_wdata), .wstrb(m_wstrb), .wlast(m_wlast),
    .bvalid(m_bvalid), .bresp(m_bresp), .bready(m_bready));

  wire e_in_valid, e_out_valid, mrst, ws_en, ws_we, ws_sel, ws_rvalid;
  wire [31:0] e_in_data, e_out_data;
  wire [2:0] ws_lane;
  wire [11:0] ws_addr;
  wire [2*QW-1:0] ws_wdata, ws_rdata;
  wire t_co, t_li, t_mm;
  wire [31:0] t_addr;
  wire [3:0] t_lg;
  wire [23:0] t_count;
  wire [5:0] mq_push, mq_full;
  wire [127:0] mq_data;
  wire em_valid, em_hold, ld_valid, ld_ready;
  wire [31:0] em_data, ld_data;

  c2_seq u_seq (.clk(clk), .rst(urst), .go(go), .start(start_p), .desc_addr(daddr), .desc_count(dcount),
    .busy(busy), .done(seq_done), .err_v(seq_err_v), .err_code(seq_err_c), .err_info(seq_err_i), .desc_done(ddone),
    .rq_v(rq_v[1:0]), .rq_a(rq_a[63:0]), .rq_n(rq_n[9:0]), .rq_g(rq_g[1:0]), .rd_v(rd_v[1:0]), .rd_d(rd_d),
    .wq_v(wq_v[0]), .wq_a(wq_a[31:0]), .wq_n(wq_n[4:0]), .wq_g(wq_g[0]), .wd_d(wd_d[127:0]), .wd_s(wd_s[15:0]), .wd_pop(wd_pop[0]),
    .in_valid(e_in_valid), .in_data(e_in_data), .out_valid(e_out_valid), .out_data(e_out_data),
    .t_co(t_co), .t_li(t_li), .t_mm(t_mm), .t_addr(t_addr), .t_lg(t_lg), .t_count(t_count), .t_idle(t_idle),
    .mq_push(mq_push), .mq_data(mq_data), .mq_full(mq_full), .lanes_idle(&lane_idle), .wr_idle(wr_idle));

  c2_tile u_tile (.clk(clk), .rst(urst), .go(go), .t_co(t_co), .t_li(t_li), .t_mm(t_mm), .t_addr(t_addr), .t_lg(t_lg),
    .t_count(t_count), .idle(t_idle), .e_valid(em_valid), .e_data(em_data), .e_hold(em_hold),
    .l_valid(ld_valid), .l_data(ld_data), .l_ready(ld_ready),
    .rq_v(rq_v[2]), .rq_a(rq_a[95:64]), .rq_n(rq_n[14:10]), .rq_g(rq_g[2]), .rd_v(rd_v[2]), .rd_d(rd_d),
    .wq_v(wq_v[1]), .wq_a(wq_a[63:32]), .wq_n(wq_n[9:5]), .wq_g(wq_g[1]), .wd_d(wd_d[255:128]), .wd_s(wd_s[31:16]), .wd_pop(wd_pop[1]),
    .err_v(tile_err_v), .err_code(tile_err_c));

  snn_engine #(.QW(QW)) u_engine (
    .clk(clk), .rst(sys_rst), .soft_rst(srst), .in_valid(e_in_valid), .in_data(e_in_data),
    .out_valid(e_out_valid), .out_data(e_out_data), .mrst(mrst),
    .s_kind(), .s_lane(), .s_slot(), .s_t(), .s_valid(), .s_last(), .s_data(), .s_ready(1'b0),
    .co_valid(1'b0), .co_data(16'd0),
    .ws_en(ws_en), .ws_we(ws_we), .ws_sel(ws_sel), .ws_lane(ws_lane), .ws_addr(ws_addr),
    .ws_wdata(ws_wdata), .ws_rvalid(ws_rvalid), .ws_rdata(ws_rdata),
    .e_valid(em_valid), .e_data(em_data), .e_hold(em_hold),
    .l_valid(ld_valid), .l_data(ld_data), .l_ready(ld_ready));

  reg module_rst = 1'b1;
  always @(posedge clk) module_rst <= srst | mrst | sys_rst;

  wire [L-1:0] w_valid, w_last, w_ready, m_valid, m_last, m_ready, c_valid, c_last, c_ready, co_v;
  wire [16*L-1:0] w_data, m_data, c_data, co_d;
  wire [5*L-1:0] m_slot;
  wire [4*L-1:0] m_t;
  genvar g;
  generate for (g = 0; g < L; g = g + 1) begin: g_lane
    c2_lane u_lane (.clk(clk), .rst(urst), .go(go), .q_push(mq_push[g]), .q_data(mq_data), .q_full(mq_full[g]),
      .idle(lane_idle[g]),
      .w_valid(w_valid[g]), .w_last(w_last[g]), .w_data(w_data[16*g +: 16]), .w_ready(w_ready[g]),
      .m_valid(m_valid[g]), .m_last(m_last[g]), .m_data(m_data[16*g +: 16]), .m_slot(m_slot[5*g +: 5]), .m_t(m_t[4*g +: 4]),
      .m_ready(m_ready[g]),
      .c_valid(c_valid[g]), .c_last(c_last[g]), .c_data(c_data[16*g +: 16]), .c_ready(c_ready[g]),
      .co_valid(co_v[g]), .co_data(co_d[16*g +: 16]),
      .rq_v(rq_v[3+g]), .rq_a(rq_a[32*(3+g) +: 32]), .rq_n(rq_n[5*(3+g) +: 5]), .rq_g(rq_g[3+g]), .rd_v(rd_v[3+g]), .rd_d(rd_d),
      .wq_v(wq_v[2+g]), .wq_a(wq_a[32*(2+g) +: 32]), .wq_n(wq_n[5*(2+g) +: 5]), .wq_g(wq_g[2+g]),
      .wd_d(wd_d[128*(2+g) +: 128]), .wd_s(wd_s[16*(2+g) +: 16]), .wd_pop(wd_pop[2+g]));
  end endgenerate

  astro_module #(.L(L), .QW(QW)) u_astro (
    .clk(clk), .rst(module_rst), .fault_flag(p1[16]), .cfg_nbase(p1[15:0]),
    .cfg_eta_fast(p2[17:0]), .cfg_eta_slow(p3[17:0]),
    .w_valid(w_valid), .w_last(w_last), .w_data(w_data), .w_ready(w_ready),
    .m_valid(m_valid), .m_last(m_last), .m_data(m_data), .m_slot(m_slot), .m_t(m_t), .m_ready(m_ready),
    .c_valid(c_valid), .c_last(c_last), .c_data(c_data), .c_ready(c_ready),
    .co_valid(co_v), .co_data(co_d),
    .ws_en(ws_en), .ws_we(ws_we), .ws_sel(ws_sel), .ws_lane(ws_lane), .ws_addr(ws_addr),
    .ws_wdata(ws_wdata), .ws_rvalid(ws_rvalid), .ws_rdata(ws_rdata),
    .px_thd_on(12'd0), .px_thd_off(12'd0), .px_thh_on(12'd0), .px_thh_off(12'd0), .px_dwell(5'd0),
    .px_in_valid(1'b0), .px_in_data(128'd0), .px_in_ready(),
    .px_out_valid(), .px_out_data(), .px_out_flags(), .px_out_last());
endmodule
`default_nettype wire
