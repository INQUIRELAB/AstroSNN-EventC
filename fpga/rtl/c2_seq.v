`timescale 1ns/1ps
`default_nettype none
module c2_seq #(
  parameter integer CREDIT = 2048
) (
  input wire clk, rst, go,
  input wire start,
  input wire [31:0] desc_addr,
  input wire [23:0] desc_count,
  output reg busy = 1'b0,
  output reg done = 1'b0,
  output reg err_v = 1'b0,
  output reg [3:0] err_code = 4'd0,
  output reg [31:0] err_info = 32'd0,
  output reg [23:0] desc_done = 24'd0,
  output wire [1:0] rq_v,
  output wire [63:0] rq_a,
  output wire [9:0] rq_n,
  input wire [1:0] rq_g,
  input wire [1:0] rd_v,
  input wire [127:0] rd_d,
  output wire wq_v,
  output wire [31:0] wq_a,
  output wire [4:0] wq_n,
  input wire wq_g,
  output wire [127:0] wd_d,
  output wire [15:0] wd_s,
  input wire wd_pop,
  output reg in_valid = 1'b0,
  output reg [31:0] in_data = 32'd0,
  input wire out_valid,
  input wire [31:0] out_data,
  output reg t_co = 1'b0,
  output reg t_li = 1'b0,
  output reg t_mm = 1'b0,
  output reg [31:0] t_addr = 32'd0,
  output reg [3:0] t_lg = 4'd0,
  output reg [23:0] t_count = 24'd0,
  input wire t_idle,
  output reg [5:0] mq_push = 6'd0,
  output reg [127:0] mq_data = 128'd0,
  input wire [5:0] mq_full,
  input wire lanes_idle,
  input wire wr_idle
);
  localparam OP_END = 4'd0, OP_FDDR = 4'd1, OP_FCON = 4'd2, OP_FENCE = 4'd3,
             OP_TCO = 4'd4, OP_TLI = 4'd5, OP_MM = 4'd6, OP_MOD = 4'd7;
  localparam M_DISC = 4'd0, M_ZERO = 4'd1, M_WR = 4'd2;

  reg [31:0] dptr = 32'd0;
  reg [23:0] dleft = 24'd0;
  reg [5:0] dinf = 6'd0;
  wire [127:0] dd;
  wire ddv;
  wire [5:0] dcnt;
  wire dpop;
  c2_fifo_d #(.W(128), .AW(5)) u_dq (.clk(clk), .rst(rst || !busy), .wr(rd_v[0]), .din(rd_d), .rd(dpop),
    .dout(dd), .dv(ddv), .count(dcnt));
  wire [4:0] dn;
  c2_blen u_bd (.addr(dptr), .left(dleft), .n(dn));
  wire [6:0] droom = 7'd32 - dcnt - dinf;
  wire [3:0] op = dd[31:28];
  wire [3:0] mode = dd[27:24];
  wire [23:0] cnt = dd[23:0];
  wire [2:0] mlane = dd[27:25];
  assign rq_v[0] = busy && dleft != 0 && {2'd0, dn} <= droom && go && !(ddv && op == OP_END);
  assign rq_a[31:0] = dptr;
  assign rq_n[4:0] = dn;

  reg f_busy = 1'b0, f_ddr = 1'b0;
  reg [23:0] f_cnt = 24'd0, f_rb = 24'd0;
  reg [31:0] f_const = 32'd0, f_addr = 32'd0;
  reg [1:0] f_wi = 2'd0;
  reg [5:0] f_inf = 6'd0;
  wire [127:0] fd;
  wire fdv;
  wire [5:0] fcnt;
  wire f_take;
  c2_fifo_d #(.W(128), .AW(5)) u_fq (.clk(clk), .rst(rst), .wr(rd_v[1]), .din(rd_d), .rd(f_take),
    .dout(fd), .dv(fdv), .count(fcnt));
  wire [4:0] fn;
  c2_blen u_bf (.addr(f_addr), .left(f_rb), .n(fn));
  wire [6:0] froom = 7'd32 - fcnt - f_inf;
  assign rq_v[1] = f_busy && f_ddr && f_rb != 0 && {2'd0, fn} <= froom && go;
  assign rq_a[63:32] = f_addr;
  assign rq_n[9:5] = fn;

  reg [12:0] credit = 13'd0;
  wire credit_ok = credit < CREDIT;
  wire f_word = f_busy && f_cnt != 0 && credit_ok && (!f_ddr || fdv);
  assign f_take = f_word && f_ddr && (f_wi == 2'd3 || f_cnt == 24'd1);

  wire [59:0] rq_out;
  wire rqv;
  wire [3:0] rq_cnt;
  wire rq_pop;
  reg rq_push = 1'b0;
  reg [59:0] rq_in;
  c2_fifo_d #(.W(60), .AW(3)) u_rq (.clk(clk), .rst(rst), .wr(rq_push), .din(rq_in), .rd(rq_pop),
    .dout(rq_out), .dv(rqv), .count(rq_cnt));

  wire [31:0] rf_d;
  wire rf_v;
  wire [11:0] rf_cnt;
  wire r_take;
  c2_fifo_b #(.W(32), .AW(11)) u_rf (.clk(clk), .rst(rst), .wr(out_valid), .din(out_data), .rd(r_take),
    .dout(rf_d), .dv(rf_v), .count(rf_cnt));

  reg r_act = 1'b0;
  reg [3:0] r_mode = 4'd0;
  reg [23:0] r_left = 24'd0, r_wq = 24'd0;
  reg [31:0] r_wa = 32'd0;
  reg [1:0] r_wi = 2'd0;
  reg [127:0] r_beat = 128'd0;
  reg [15:0] r_strb = 16'd0;
  reg [5:0] r_unc = 6'd0;
  reg [31:0] r_index = 32'd0;
  wire [5:0] wcnt;
  wire wfull = wcnt >= 6'd30;
  assign r_take = r_act && r_left != 0 && rf_v && (r_mode != M_WR || !wfull);
  wire r_flush = r_take && r_mode == M_WR && (r_wi == 2'd3 || r_left == 24'd1);
  wire [127:0] r_nbeat = r_beat | ({96'd0, rf_d} << (32 * r_wi));
  wire [15:0] r_nstrb = r_strb | (16'h000f << (4 * r_wi));
  c2_fifo_d #(.W(144), .AW(5)) u_wq (.clk(clk), .rst(rst), .wr(r_flush), .din({r_nstrb, r_nbeat}), .rd(wd_pop),
    .dout({wd_s, wd_d}), .dv(), .count(wcnt));
  wire [4:0] wn;
  c2_blen u_bw (.addr(r_wa), .left(r_wq), .n(wn));
  assign wq_v = r_act && r_mode == M_WR && r_wq != 0 && r_unc >= {1'b0, wn} && go;
`ifdef BUG_OOB
  assign wq_a = r_wa + 32'h10000000;
`else
  assign wq_a = r_wa;
`endif
  assign wq_n = wn;
  wire unc_add = r_flush;

  wire quiet = !f_busy && rq_cnt == 0 && !r_act && credit == 0 && wcnt == 0 && t_idle && lanes_idle && wr_idle && !rq_push;
  reg [2:0] qcount = 3'd0;
  wire tpend = t_co || t_li || t_mm;
  wire settled = qcount == 3'd7;
  wire can = busy && ddv && go;
  wire do_end = can && op == OP_END && settled && dinf == 6'd0;
  wire do_fence = can && op == OP_FENCE && settled;
  wire do_feed = can && (op == OP_FDDR || op == OP_FCON) && !f_busy && rq_cnt < 4'd6 && !rq_push;
  wire do_tile = can && (op == OP_TCO || op == OP_TLI || op == OP_MM) && t_idle && !tpend;
  wire do_mod = can && op == OP_MOD && mlane < 3'd6 && !mq_full[mlane] && mq_push == 6'd0;
  wire bad_op = can && (op > OP_MOD || (op == OP_MOD && mlane > 3'd5));
  assign dpop = do_end || do_fence || do_feed || do_tile || do_mod;
  assign rq_pop = !r_act && rqv;

  always @(posedge clk) begin
    rq_push <= 1'b0;
    in_valid <= 1'b0;
    t_co <= 1'b0; t_li <= 1'b0; t_mm <= 1'b0;
    mq_push <= 6'd0;
    err_v <= 1'b0;
    done <= 1'b0;
    if (rst) begin
      busy <= 1'b0; dleft <= 0; dinf <= 0; f_busy <= 1'b0; f_inf <= 0; credit <= 0;
      r_act <= 1'b0; r_unc <= 0; qcount <= 0; desc_done <= 0; r_index <= 0;
    end else begin
      if (start && !busy) begin
        busy <= 1'b1; dptr <= desc_addr; dleft <= desc_count; dinf <= 0; desc_done <= 0; r_index <= 0;
      end
      if (rq_g[0]) begin dptr <= dptr + {23'd0, dn, 4'd0}; dleft <= dleft - dn; end
      dinf <= dinf + (rq_g[0] ? dn : 5'd0) - rd_v[0];
      qcount <= (quiet && !tpend && !dpop) ? (qcount == 3'd7 ? qcount : qcount + 1'b1) : 3'd0;
      if (do_end) begin busy <= 1'b0; done <= 1'b1; end
      if (do_feed) begin
        f_busy <= cnt != 0; f_ddr <= op == OP_FDDR; f_cnt <= cnt; f_const <= dd[63:32];
        f_addr <= {dd[63:36], 4'd0}; f_wi <= dd[35:34];
        f_rb <= ({22'd0, dd[35:34]} + cnt + 24'd3) >> 2;
        rq_push <= cnt != 0; rq_in <= {mode, cnt, dd[95:64]};
        if (mode > M_WR || (mode == M_WR && dd[67:64] != 4'd0)) begin err_v <= 1'b1; err_code <= 4'd9; err_info <= {8'd0, desc_done}; end
      end
      if (do_tile) begin
        t_co <= op == OP_TCO; t_li <= op == OP_TLI; t_mm <= op == OP_MM;
        t_addr <= dd[63:32]; t_lg <= dd[67:64]; t_count <= cnt;
      end
      if (do_mod) begin mq_push[mlane] <= 1'b1; mq_data <= dd; end
      if (bad_op) begin err_v <= 1'b1; err_code <= 4'd10; err_info <= {8'd0, desc_done}; end
      if (dpop) desc_done <= desc_done + 1'b1;
      if (rq_g[1]) begin f_addr <= f_addr + {23'd0, fn, 4'd0}; f_rb <= f_rb - fn; end
      f_inf <= f_inf + (rq_g[1] ? fn : 5'd0) - rd_v[1];
      if (f_word) begin
        in_valid <= 1'b1;
        in_data <= f_ddr ? fd[32*f_wi +: 32] : f_const;
        f_cnt <= f_cnt - 1'b1;
        f_wi <= f_wi + 1'b1;
        if (f_cnt == 24'd1) f_busy <= 1'b0;
      end
      credit <= credit + f_word - r_take;
      if (rq_pop) begin
        r_act <= 1'b1; r_mode <= rq_out[59:56]; r_left <= rq_out[55:32];
        r_wa <= rq_out[31:0]; r_wq <= (rq_out[55:32] + 24'd3) >> 2; r_wi <= 2'd0;
        r_beat <= 128'd0; r_strb <= 16'd0;
      end
      if (r_take) begin
        r_left <= r_left - 1'b1;
        r_index <= r_index + 1'b1;
        if (r_mode == M_ZERO && rf_d != 32'd0 && err_code != 4'd8) begin
          err_v <= 1'b1; err_code <= 4'd8; err_info <= r_index;
        end
        if (r_mode == M_WR) begin
          if (r_flush) begin r_beat <= 128'd0; r_strb <= 16'd0; r_wi <= 2'd0; end
          else begin r_beat <= r_nbeat; r_strb <= r_nstrb; r_wi <= r_wi + 1'b1; end
        end
      end
      if (wq_g) begin r_wa <= r_wa + {23'd0, wn, 4'd0}; r_wq <= r_wq - wn; end
      r_unc <= r_unc + unc_add - (wq_g ? wn : 5'd0);
      if (r_act && r_left == 0 && (r_mode != M_WR || r_wq == 0) && !r_take) r_act <= 1'b0;
      if (out_valid && rf_cnt >= 12'd2047) begin err_v <= 1'b1; err_code <= 4'd11; err_info <= r_index; end
    end
  end
endmodule
`default_nettype wire
