`timescale 1ns/1ps
`default_nettype none
module c2_lane (
  input wire clk, rst, go,
  input wire q_push,
  input wire [127:0] q_data,
  output wire q_full,
  output wire idle,
  output reg w_valid = 1'b0,
  output reg w_last = 1'b0,
  output reg [15:0] w_data = 16'd0,
  input wire w_ready,
  output wire m_valid,
  output wire m_last,
  output wire [15:0] m_data,
  output wire [4:0] m_slot,
  output wire [3:0] m_t,
  input wire m_ready,
  output wire c_valid,
  output wire c_last,
  output wire [15:0] c_data,
  input wire c_ready,
  input wire co_valid,
  input wire [15:0] co_data,
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
  input wire wd_pop
);
  localparam S_IDLE = 3'd0, S_WREQ = 3'd1, S_WWAIT = 3'd2, S_W0 = 3'd3, S_W1 = 3'd4, S_STREAM = 3'd5, S_DRAIN = 3'd6;
  wire [127:0] qd;
  wire qv;
  wire [2:0] qc;
  reg q_pop = 1'b0;
  c2_fifo_d #(.W(128), .AW(2)) u_q (.clk(clk), .rst(rst), .wr(q_push), .din(q_data), .rd(q_pop), .dout(qd), .dv(qv), .count(qc));
  assign q_full = qc >= 3'd3;

  reg [2:0] st = S_IDLE;
  reg [4:0] slot = 5'd0;
  reg [3:0] tt = 4'd0;
  reg [15:0] nb = 16'd0;
  reg [31:0] src = 32'd0, dst = 32'd0, wad = 32'd0;
  reg [15:0] wmax = 16'd0;
  assign m_slot = slot;
  assign m_t = tt;

  reg [31:0] ra = 32'd0;
  reg [23:0] rleft = 24'd0;
  reg rph2 = 1'b1;
  reg [6:0] rinf = 7'd0;
  wire [127:0] fd;
  wire fdv;
  wire [6:0] fcnt;
  wire f_pop;
  c2_fifo_d #(.W(128), .AW(6)) u_in (.clk(clk), .rst(rst), .wr(rd_v), .din(rd_d), .rd(f_pop), .dout(fd), .dv(fdv), .count(fcnt));
  wire [4:0] rn;
  c2_blen u_br (.addr(ra), .left(rleft), .n(rn));
  wire [7:0] room = 8'd64 - fcnt - rinf;
  assign rq_v = rleft != 0 && {3'd0, rn} <= room && go;
  assign rq_a = ra;
  assign rq_n = rn;

  reg ph = 1'b0;
  reg [2:0] vi = 3'd0;
  reg [18:0] vcnt = 19'd0;
  wire [18:0] nval = {nb, 3'd0};
  wire [15:0] cur = fd[16*vi +: 16];
  wire lastv = vcnt == nval - 1'b1;
  reg [18:0] cfed = 19'd0;
  reg [15:0] opop = 16'd0;
  wire c_room = cfed - {opop, 3'd0} < 19'd248;
  wire sv = st == S_STREAM && fdv;
  assign m_valid = sv && !ph;
  assign c_valid = sv && ph && c_room;
  assign m_last = lastv;
  assign c_last = lastv;
  assign m_data = cur;
  assign c_data = cur;
  wire acc = (m_valid && m_ready) || (c_valid && c_ready);
  wire w_take = st == S_WWAIT && fdv;
  assign f_pop = (acc && (vi == 3'd7)) || w_take;

  reg [2:0] oi = 3'd0;
  reg [111:0] obeat = 112'd0;
  reg [18:0] ogot = 19'd0;
  wire opush = co_valid && oi == 3'd7;
`ifdef BUG_LANE
  wire [127:0] onew = {obeat[15:0], co_data, obeat[111:16]};
`else
  wire [127:0] onew = {co_data, obeat};
`endif
  wire [5:0] ocnt;
  c2_fifo_d #(.W(128), .AW(5)) u_out (.clk(clk), .rst(rst), .wr(opush), .din(onew), .rd(wd_pop), .dout(wd_d), .dv(), .count(ocnt));
  assign wd_s = 16'hffff;
  reg [31:0] wa = 32'd0;
  reg [23:0] wleft = 24'd0;
  reg [5:0] unc = 6'd0;
  wire [4:0] wn;
  c2_blen u_bw (.addr(wa), .left(wleft), .n(wn));
  assign wq_v = wleft != 0 && unc >= {1'b0, wn} && go;
  assign wq_a = wa;
  assign wq_n = wn;

  assign idle = st == S_IDLE && !qv && !q_push && ocnt == 6'd0;

  always @(posedge clk) begin
    q_pop <= 1'b0;
    if (rst) begin
      st <= S_IDLE; rleft <= 0; rinf <= 0; rph2 <= 1'b1; ph <= 1'b0; vi <= 0; vcnt <= 0; cfed <= 0; opop <= 0;
      oi <= 0; ogot <= 0; wleft <= 0; unc <= 0; w_valid <= 1'b0; w_last <= 1'b0;
    end else begin
      if (rq_g) begin
        if (!rph2 && rleft == {19'd0, rn}) begin ra <= src; rleft <= {8'd0, nb}; rph2 <= 1'b1; end
        else begin ra <= ra + {23'd0, rn, 4'd0}; rleft <= rleft - rn; end
      end
      rinf <= rinf + (rq_g ? rn : 5'd0) - rd_v;
      if (wq_g) begin wa <= wa + {23'd0, wn, 4'd0}; wleft <= wleft - wn; end
      unc <= unc + opush - (wq_g ? wn : 5'd0);
      if (wd_pop) opop <= opop + 1'b1;
      if (co_valid) begin
        ogot <= ogot + 1'b1;
        oi <= oi + 1'b1;
        if (oi != 3'd7) obeat[16*oi +: 16] <= co_data;
      end
      case (st)
        S_IDLE: if (qv && !q_pop) begin
          slot <= qd[24:20]; tt <= qd[19:16]; nb <= qd[15:0];
          src <= qd[63:32]; dst <= qd[95:64]; wad <= qd[127:96];
          ra <= {qd[127:100], 4'd0}; rleft <= 24'd1; rph2 <= 1'b1;
          q_pop <= 1'b1;
          st <= S_WREQ;
        end
        S_WREQ: if (rleft == 0) st <= S_WWAIT;
        S_WWAIT: if (fdv) begin
          w_data <= fd[32*wad[3:2] +: 16];
          w_last <= 1'b0; w_valid <= 1'b1;
          wmax <= fd[32*wad[3:2] + 16 +: 16];
          st <= S_W0;
        end
        S_W0: if (w_ready) begin
          w_data <= wmax; w_last <= 1'b1;
          st <= S_W1;
        end
        S_W1: if (w_ready) begin
          w_valid <= 1'b0; w_last <= 1'b0;
          ra <= src; rleft <= {8'd0, nb}; rph2 <= 1'b0;
          ph <= 1'b0; vi <= 0; vcnt <= 0; cfed <= 0; opop <= 0; oi <= 0; ogot <= 0;
          wa <= dst; wleft <= {8'd0, nb};
          st <= S_STREAM;
        end
        S_STREAM: begin
          if (acc) begin
            vi <= vi + 1'b1;
            if (ph) cfed <= cfed + 1'b1;
            if (lastv) begin
              vcnt <= 0;
              if (ph) st <= S_DRAIN;
              ph <= 1'b1;
            end else vcnt <= vcnt + 1'b1;
          end
        end
        S_DRAIN: if (ogot == nval && wleft == 0 && ocnt == 6'd0 && !co_valid) st <= S_IDLE;
        default: st <= S_IDLE;
      endcase
    end
  end
endmodule
`default_nettype wire
