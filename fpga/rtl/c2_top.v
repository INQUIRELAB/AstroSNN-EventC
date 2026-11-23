`timescale 1ns/1ps
`default_nettype none
module c2_top (
  input wire clk,
  input wire rstn,
  input wire [11:0] S_AXI_AWADDR,
  input wire [2:0] S_AXI_AWPROT,
  input wire S_AXI_AWVALID,
  output wire S_AXI_AWREADY,
  input wire [31:0] S_AXI_WDATA,
  input wire [3:0] S_AXI_WSTRB,
  input wire S_AXI_WVALID,
  output wire S_AXI_WREADY,
  output wire [1:0] S_AXI_BRESP,
  output wire S_AXI_BVALID,
  input wire S_AXI_BREADY,
  input wire [11:0] S_AXI_ARADDR,
  input wire [2:0] S_AXI_ARPROT,
  input wire S_AXI_ARVALID,
  output wire S_AXI_ARREADY,
  output wire [31:0] S_AXI_RDATA,
  output wire [1:0] S_AXI_RRESP,
  output wire S_AXI_RVALID,
  input wire S_AXI_RREADY,
  output wire [0:0] M_AXI_AWID,
  output wire [31:0] M_AXI_AWADDR,
  output wire [7:0] M_AXI_AWLEN,
  output wire [2:0] M_AXI_AWSIZE,
  output wire [1:0] M_AXI_AWBURST,
  output wire M_AXI_AWLOCK,
  output wire [3:0] M_AXI_AWCACHE,
  output wire [2:0] M_AXI_AWPROT,
  output wire [3:0] M_AXI_AWQOS,
  output wire M_AXI_AWVALID,
  input wire M_AXI_AWREADY,
  output wire [127:0] M_AXI_WDATA,
  output wire [15:0] M_AXI_WSTRB,
  output wire M_AXI_WLAST,
  output wire M_AXI_WVALID,
  input wire M_AXI_WREADY,
  input wire [0:0] M_AXI_BID,
  input wire [1:0] M_AXI_BRESP,
  input wire M_AXI_BVALID,
  output wire M_AXI_BREADY,
  output wire [0:0] M_AXI_ARID,
  output wire [31:0] M_AXI_ARADDR,
  output wire [7:0] M_AXI_ARLEN,
  output wire [2:0] M_AXI_ARSIZE,
  output wire [1:0] M_AXI_ARBURST,
  output wire M_AXI_ARLOCK,
  output wire [3:0] M_AXI_ARCACHE,
  output wire [2:0] M_AXI_ARPROT,
  output wire [3:0] M_AXI_ARQOS,
  output wire M_AXI_ARVALID,
  input wire M_AXI_ARREADY,
  input wire [0:0] M_AXI_RID,
  input wire [127:0] M_AXI_RDATA,
  input wire [1:0] M_AXI_RRESP,
  input wire M_AXI_RLAST,
  input wire M_AXI_RVALID,
  output wire M_AXI_RREADY
);
  wire [31:0] usr;
  c2_build u_build (.word(usr));
  assign M_AXI_AWID = 1'b0;
  assign M_AXI_AWSIZE = 3'b100;
  assign M_AXI_AWBURST = 2'b01;
  assign M_AXI_AWLOCK = 1'b0;
  assign M_AXI_AWCACHE = 4'b0010;
  assign M_AXI_AWPROT = 3'b000;
  assign M_AXI_AWQOS = 4'b0000;
  assign M_AXI_ARID = 1'b0;
  assign M_AXI_ARSIZE = 3'b100;
  assign M_AXI_ARBURST = 2'b01;
  assign M_AXI_ARLOCK = 1'b0;
  assign M_AXI_ARCACHE = 4'b0010;
  assign M_AXI_ARPROT = 3'b000;
  assign M_AXI_ARQOS = 4'b0000;
  c2_core u_core (
    .clk(clk), .rstn(rstn), .usr_access(usr),
    .s_awaddr(S_AXI_AWADDR), .s_awvalid(S_AXI_AWVALID), .s_awready(S_AXI_AWREADY),
    .s_wdata(S_AXI_WDATA), .s_wstrb(S_AXI_WSTRB), .s_wvalid(S_AXI_WVALID), .s_wready(S_AXI_WREADY),
    .s_bresp(S_AXI_BRESP), .s_bvalid(S_AXI_BVALID), .s_bready(S_AXI_BREADY),
    .s_araddr(S_AXI_ARADDR), .s_arvalid(S_AXI_ARVALID), .s_arready(S_AXI_ARREADY),
    .s_rdata(S_AXI_RDATA), .s_rresp(S_AXI_RRESP), .s_rvalid(S_AXI_RVALID), .s_rready(S_AXI_RREADY),
    .m_arvalid(M_AXI_ARVALID), .m_arready(M_AXI_ARREADY), .m_araddr(M_AXI_ARADDR), .m_arlen(M_AXI_ARLEN),
    .m_rvalid(M_AXI_RVALID), .m_rdata(M_AXI_RDATA), .m_rresp(M_AXI_RRESP), .m_rlast(M_AXI_RLAST), .m_rready(M_AXI_RREADY),
    .m_awvalid(M_AXI_AWVALID), .m_awready(M_AXI_AWREADY), .m_awaddr(M_AXI_AWADDR), .m_awlen(M_AXI_AWLEN),
    .m_wvalid(M_AXI_WVALID), .m_wready(M_AXI_WREADY), .m_wdata(M_AXI_WDATA), .m_wstrb(M_AXI_WSTRB), .m_wlast(M_AXI_WLAST),
    .m_bvalid(M_AXI_BVALID), .m_bresp(M_AXI_BRESP), .m_bready(M_AXI_BREADY));
endmodule
`default_nettype wire
