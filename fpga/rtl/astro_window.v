`default_nettype none
module astro_window (
  input  wire               clk,
  input  wire               rst,
  input  wire               w_valid,
  input  wire               w_last,
  input  wire signed [15:0] w_data,
  output wire               w_ready,
  input  wire               pop,
  output wire               ne,
  output wire signed [15:0] off,
  output wire [2:0]         sh
);
  reg signed [15:0] mn, mx, pmn, pmx;
  reg               first, pv;
  reg [2:0]         cnt;
  reg [1:0]         wp, rp;
  reg [18:0]        fq [0:3];

  assign w_ready = ({1'b0, cnt} + pv) < 4'd4;
  wire acc = w_valid & w_ready;
  wire signed [15:0] nmn = (first || w_data < mn) ? w_data : mn;
  wire signed [15:0] nmx = (first || w_data > mx) ? w_data : mx;

  wire [16:0] d = $signed({pmx[15], pmx}) - $signed({pmn[15], pmn});
`ifdef BUG_WINEDGE
  wire [16:0] dd = (d == 17'd0) ? 17'd0 : d - 1'b1;
`else
  wire [16:0] dd = d;
`endif
  wire [2:0] s = dd[15] ? 3'd6 : dd[14] ? 3'd5 : dd[13] ? 3'd4 : dd[12] ? 3'd3 : dd[11] ? 3'd2 : dd[10] ? 3'd1 : 3'd0;

  assign ne = (cnt != 3'd0);
  assign off = fq[rp][18:3];
  assign sh = fq[rp][2:0];

  always @(posedge clk) begin
    if (rst) begin
      first <= 1'b1;
      pv <= 1'b0;
      cnt <= 3'd0;
      wp <= 2'd0;
      rp <= 2'd0;
    end else begin
      pv <= acc & w_last;
      if (acc) begin
        mn <= nmn;
        mx <= nmx;
        first <= w_last;
      end
      if (acc & w_last) begin
        pmn <= nmn;
        pmx <= nmx;
      end
      if (pv) begin
        fq[wp] <= {pmn, s};
        wp <= wp + 1'b1;
      end
      if (pop) rp <= rp + 1'b1;
      cnt <= cnt + pv - pop;
    end
  end
endmodule
`default_nettype wire
