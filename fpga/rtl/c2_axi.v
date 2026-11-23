`timescale 1ns/1ps
`default_nettype none
module c2_rd #(
  parameter integer NR = 9
) (
  input wire clk, rst, go,
  input wire [31:0] base,
  input wire [32:0] lim_end,
  input wire [NR-1:0] rq_v,
  input wire [32*NR-1:0] rq_a,
  input wire [5*NR-1:0] rq_n,
  output reg [NR-1:0] rq_g = 0,
  output reg [NR-1:0] rd_v = 0,
  output reg [127:0] rd_d = 128'd0,
  output reg err_v = 1'b0,
  output reg [3:0] err_code = 4'd0,
  output reg [31:0] err_addr = 32'd0,
  output wire idle,
  output wire [5:0] outstanding,
  output reg arvalid = 1'b0,
  input wire arready,
  output reg [31:0] araddr = 32'd0,
  output reg [7:0] arlen = 8'd0,
  input wire rvalid,
  input wire [127:0] rdata,
  input wire [1:0] rresp,
  input wire rlast,
  output wire rready
);
  reg s_v = 1'b0;
  reg [31:0] s_a = 32'd0;
  reg [4:0] s_n = 5'd0;
  reg [3:0] s_id = 4'd0;
  reg [3:0] ptr = 4'd0;
  reg [3:0] pick;
  reg found;
  integer i, k;
  always @* begin
    found = 1'b0; pick = 4'd0;
    for (i = 0; i < NR; i = i + 1) begin
      k = (ptr + i) % NR;
      if (!found && rq_v[k]) begin found = 1'b1; pick = k; end
    end
  end
  wire [32:0] s_end = {1'b0, s_a} + {24'd0, s_n, 4'd0};
  wire [12:0] s_4k = {1'b0, s_a[11:0]} + {4'd0, s_n, 4'd0};
  wire bad_align = s_a[3:0] != 4'd0;
  wire bad_len = s_n == 5'd0 || s_n > 5'd16;
  wire bad_4k = s_4k > 13'd4096;
  wire bad_win = s_a < base || s_end > lim_end;
`ifdef BUG_NOCLAMP
  wire legal = 1'b1;
`else
  wire legal = !bad_align && !bad_len && !bad_4k && !bad_win;
`endif
  reg [3:0] tag [0:31];
  reg [4:0] tw = 5'd0, tr = 5'd0;
  reg [5:0] tc = 6'd0;
  wire push = s_v && !arvalid && go && legal && tc < 6'd30;
  wire pop = rvalid && rlast;
  assign rready = 1'b1;
  assign outstanding = tc;
  assign idle = tc == 6'd0 && !arvalid;
  always @(posedge clk) begin
    rq_g <= 0;
    rd_v <= 0;
    err_v <= 1'b0;
    if (push) tag[tw] <= s_id;
    if (rvalid) begin rd_v[tag[tr]] <= 1'b1; rd_d <= rdata; end
    if (rst) begin
      s_v <= 1'b0; arvalid <= 1'b0; tw <= 0; tr <= 0; tc <= 0; ptr <= 0;
    end else begin
      if (!s_v && go && found) begin
        s_v <= 1'b1; s_a <= rq_a[32*pick +: 32]; s_n <= rq_n[5*pick +: 5]; s_id <= pick;
        rq_g[pick] <= 1'b1;
        ptr <= (pick + 1 == NR) ? 4'd0 : pick + 1'b1;
      end
      if (s_v && !arvalid && go && !legal) begin
        err_v <= 1'b1;
        err_addr <= s_a;
        err_code <= bad_align ? 4'd4 : bad_len ? 4'd3 : bad_4k ? 4'd2 : 4'd1;
      end
      if (push) begin
        arvalid <= 1'b1; araddr <= s_a; arlen <= {3'd0, s_n - 1'b1}; s_v <= 1'b0; tw <= tw + 1'b1;
      end
      if (arvalid && arready) arvalid <= 1'b0;
      if (pop) tr <= tr + 1'b1;
      tc <= tc + push - pop;
      if (rvalid && rresp != 2'b00) begin err_v <= 1'b1; err_code <= 4'd5; end
    end
  end
endmodule

module c2_wr #(
  parameter integer NW = 8
) (
  input wire clk, rst, go,
  input wire [31:0] base,
  input wire [32:0] lim_end,
  input wire [NW-1:0] wq_v,
  input wire [32*NW-1:0] wq_a,
  input wire [5*NW-1:0] wq_n,
  output reg [NW-1:0] wq_g = 0,
  input wire [128*NW-1:0] wd_d,
  input wire [16*NW-1:0] wd_s,
  output wire [NW-1:0] wd_pop,
  output reg err_v = 1'b0,
  output reg [3:0] err_code = 4'd0,
  output reg [31:0] err_addr = 32'd0,
  output wire idle,
  output wire [5:0] outstanding,
  output reg awvalid = 1'b0,
  input wire awready,
  output reg [31:0] awaddr = 32'd0,
  output reg [7:0] awlen = 8'd0,
  output reg wvalid = 1'b0,
  input wire wready,
  output reg [127:0] wdata = 128'd0,
  output reg [15:0] wstrb = 16'd0,
  output reg wlast = 1'b0,
  input wire bvalid,
  input wire [1:0] bresp,
  output wire bready
);
  reg s_v = 1'b0;
  reg [31:0] s_a = 32'd0;
  reg [4:0] s_n = 5'd0;
  reg [3:0] s_id = 4'd0;
  reg [3:0] ptr = 4'd0;
  reg [3:0] pick;
  reg found;
  integer i, k;
  always @* begin
    found = 1'b0; pick = 4'd0;
    for (i = 0; i < NW; i = i + 1) begin
      k = (ptr + i) % NW;
      if (!found && wq_v[k]) begin found = 1'b1; pick = k; end
    end
  end
  wire [32:0] s_end = {1'b0, s_a} + {24'd0, s_n, 4'd0};
  wire [12:0] s_4k = {1'b0, s_a[11:0]} + {4'd0, s_n, 4'd0};
  wire bad_align = s_a[3:0] != 4'd0;
  wire bad_len = s_n == 5'd0 || s_n > 5'd16;
  wire bad_4k = s_4k > 13'd4096;
  wire bad_win = s_a < base || s_end > lim_end;
`ifdef BUG_NOCLAMP
  wire legal = 1'b1;
`else
  wire legal = !bad_align && !bad_len && !bad_4k && !bad_win;
`endif
  reg [8:0] wo [0:31];
  reg [4:0] ow = 5'd0, orp = 5'd0;
  reg [5:0] oc = 6'd0;
  reg [5:0] bc = 6'd0;
  reg [4:0] wb = 5'd0;
  wire push = s_v && !awvalid && go && legal && oc < 6'd30 && bc < 6'd30;
  wire [3:0] hid = wo[orp][8:5];
  wire [4:0] hn = wo[orp][4:0];
  wire load = oc != 6'd0 && (!wvalid || wready);
  wire hlast = wb + 1'b1 == hn;
  genvar g;
  generate for (g = 0; g < NW; g = g + 1) begin: g_pop
    assign wd_pop[g] = load && hid == g;
  end endgenerate
  assign bready = 1'b1;
  assign outstanding = bc;
  assign idle = bc == 6'd0 && !awvalid && oc == 6'd0 && !wvalid;
  always @(posedge clk) begin
    wq_g <= 0;
    err_v <= 1'b0;
    if (push) wo[ow] <= {s_id, s_n};
    if (load) begin
      wdata <= wd_d[128*hid +: 128];
      wstrb <= wd_s[16*hid +: 16];
      wlast <= hlast;
    end
    if (rst) begin
      s_v <= 1'b0; awvalid <= 1'b0; wvalid <= 1'b0; ow <= 0; orp <= 0; oc <= 0; bc <= 0; wb <= 0; ptr <= 0;
    end else begin
      if (!s_v && go && found) begin
        s_v <= 1'b1; s_a <= wq_a[32*pick +: 32]; s_n <= wq_n[5*pick +: 5]; s_id <= pick;
        wq_g[pick] <= 1'b1;
        ptr <= (pick + 1 == NW) ? 4'd0 : pick + 1'b1;
      end
      if (s_v && !awvalid && go && !legal) begin
        err_v <= 1'b1;
        err_addr <= s_a;
        err_code <= bad_align ? 4'd4 : bad_len ? 4'd3 : bad_4k ? 4'd2 : 4'd1;
      end
      if (push) begin
        awvalid <= 1'b1; awaddr <= s_a; awlen <= {3'd0, s_n - 1'b1}; s_v <= 1'b0; ow <= ow + 1'b1;
      end
      if (awvalid && awready) awvalid <= 1'b0;
      if (load) begin
        wvalid <= 1'b1;
        if (hlast) begin wb <= 5'd0; orp <= orp + 1'b1; end
        else wb <= wb + 1'b1;
      end else if (wready) wvalid <= 1'b0;
      oc <= oc + push - (load && hlast);
      bc <= bc + push - bvalid;
      if (bvalid && bresp != 2'b00) begin err_v <= 1'b1; err_code <= 4'd6; end
    end
  end
endmodule
`default_nettype wire
