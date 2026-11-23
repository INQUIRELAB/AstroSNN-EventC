`timescale 1ns/1ps
`default_nettype none
module c2_blen (
  input wire [31:0] addr,
  input wire [23:0] left,
  output wire [4:0] n
);
  wire [8:0] room = 9'd256 - {1'b0, addr[11:4]};
`ifdef BUG_4K
  wire [8:0] lim = 9'd16;
`else
  wire [8:0] lim = (room < 9'd16) ? room : 9'd16;
`endif
  assign n = (left < {15'd0, lim}) ? left[4:0] : lim[4:0];
endmodule

module c2_fifo_d #(
  parameter integer W = 32,
  parameter integer AW = 5
) (
  input wire clk, rst,
  input wire wr,
  input wire [W-1:0] din,
  input wire rd,
  output reg [W-1:0] dout = {W{1'b0}},
  output reg dv = 1'b0,
  output wire [AW:0] count
);
  (* ram_style = "distributed" *) reg [W-1:0] mem [0:(1<<AW)-1];
  reg [AW-1:0] wp = 0, rp = 0;
  reg [AW:0] mc = 0;
  wire load = mc != 0 && (!dv || rd);
  assign count = mc + dv;
  always @(posedge clk) begin
    if (wr) mem[wp] <= din;
    if (load) dout <= mem[rp];
    if (rst) begin
      wp <= 0; rp <= 0; mc <= 0; dv <= 1'b0;
    end else begin
      if (wr) wp <= wp + 1'b1;
      if (load) rp <= rp + 1'b1;
      mc <= mc + wr - load;
      if (load) dv <= 1'b1;
      else if (rd) dv <= 1'b0;
    end
  end
endmodule

module c2_fifo_b #(
  parameter integer W = 32,
  parameter integer AW = 11
) (
  input wire clk, rst,
  input wire wr,
  input wire [W-1:0] din,
  input wire rd,
  output reg [W-1:0] dout = {W{1'b0}},
  output reg dv = 1'b0,
  output wire [AW:0] count
);
  (* ram_style = "block" *) reg [W-1:0] mem [0:(1<<AW)-1];
  reg [AW-1:0] wp = 0, rp = 0;
  reg [AW:0] mc = 0;
  reg [W-1:0] q = {W{1'b0}};
  reg qv = 1'b0;
  wire take = qv && (!dv || rd);
  wire load = mc != 0 && (!qv || take);
  assign count = mc + qv + dv;
  always @(posedge clk) begin
    if (wr) mem[wp] <= din;
    if (load) q <= mem[rp];
    if (take) dout <= q;
    if (rst) begin
      wp <= 0; rp <= 0; mc <= 0; qv <= 1'b0; dv <= 1'b0;
    end else begin
      if (wr) wp <= wp + 1'b1;
      if (load) rp <= rp + 1'b1;
      mc <= mc + wr - load;
      if (load) qv <= 1'b1;
      else if (take) qv <= 1'b0;
      if (take) dv <= 1'b1;
      else if (rd) dv <= 1'b0;
    end
  end
endmodule
`default_nettype wire
