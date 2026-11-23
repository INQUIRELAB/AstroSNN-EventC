`timescale 1ns/1ps
`default_nettype none
module snn_engine #(
  parameter integer QW = 32,
  parameter integer F_L0 = 7,
  parameter integer F_LN = 10
) (
  input wire clk, rst, soft_rst, in_valid,
  input wire [31:0] in_data,
  output reg out_valid = 1'b0,
  output reg [31:0] out_data = 32'd0,
  output reg mrst = 1'b0,
  output reg [1:0] s_kind = 2'd0,
  output reg [2:0] s_lane = 3'd0,
  output reg [4:0] s_slot = 5'd0,
  output reg [3:0] s_t = 4'd0,
  output wire s_valid,
  output wire s_last,
  output wire [15:0] s_data,
  input wire s_ready,
  input wire co_valid,
  input wire [15:0] co_data,
  output reg ws_en = 1'b0,
  output reg ws_we = 1'b0,
  output reg ws_sel = 1'b0,
  output reg [2:0] ws_lane = 3'd0,
  output reg [11:0] ws_addr = 12'd0,
  output reg [2*QW-1:0] ws_wdata = {(2*QW){1'b0}},
  input wire ws_rvalid,
  input wire [2*QW-1:0] ws_rdata,
  output reg e_valid = 1'b0,
  output wire [31:0] e_data,
  input wire e_hold,
  input wire l_valid,
  input wire [31:0] l_data,
  output wire l_ready
);
  localparam CMD=0, WCOUNT=1, WDATA=2, TCOUNT=3, TDATA=4,
             DATA=5, INIT=6, ISSUE=7, FLUSH=8, LIF=9, STORE=10,
             READ=11, COUNT=12, PRED=13, CCOUNT=14, CLEAR=15,
             EMIT=16, LOADC=17, MSTREAM=18, WSCOUNT=19, WSWDATA=20, WSRDATA=21;
  localparam [1:0] M_NORMAL=2'd0, M_CO=2'd1, M_LI=2'd2;
  reg [4:0] state = CMD;
  reg [1:0] mode = M_NORMAL;
  reg [31:0] mbuf = 32'd0;
  reg [1:0] mcnt = 2'd0;
  reg mbuf_empty = 1'b1;
  reg mlastw = 1'b0;
  reg [13:0] mwords = 14'd0;
  reg [12:0] pend = 13'd0;
  reg pend_zero = 1'b1;
  reg co_half = 1'b0;
  reg [15:0] co_hold = 16'd0;
  reg ws_rd = 1'b0, ws_have = 1'b0, ws_wait = 1'b0;
  reg [11:0] ws_cnt = 12'd0, ws_ptr = 12'd0;
  reg [1:0] ws_part = 2'd0;
  reg [31:0] ws_w0 = 32'd0, ws_w1 = 32'd0;
  reg [2*QW-1:0] ws_q = {(2*QW){1'b0}};
  reg [6:0] xi = 7'd0;
  reg [31:0] emit_q = 32'd0;
  wire cword = state==MSTREAM && s_kind==2'd2;
  (* ram_style = "block" *) reg [31:0] fifo [0:4095];
  reg [11:0] wrptr=0, rdptr=0;
  reg [12:0] occupancy=0;
  reg [31:0] head_int, head;
  reg head_valid=0;
  reg [1:0] fetch_pending=0;
  wire consume = head_valid && !rst && !soft_rst && mbuf_empty && (cword || pend_zero) &&
    (state==CMD || state==WCOUNT || state==WDATA || state==TCOUNT ||
     state==TDATA || state==DATA || state==READ || state==CCOUNT ||
     state==MSTREAM || state==WSCOUNT ||
     state==WSWDATA || (state==WSRDATA && ws_have));
  wire fetch = !soft_rst && !rst && occupancy!=0 && !(|fetch_pending) && (!head_valid || consume);
  always @(posedge clk) begin
    if (in_valid && !rst && !soft_rst) fifo[wrptr]<=in_data;
    if (fetch) head_int<=fifo[rdptr];
    head<=head_int;
    if (soft_rst) begin
      wrptr<=0; rdptr<=0; occupancy<=0; head_valid<=0; fetch_pending<=0;
    end else begin
      if (in_valid && !rst) wrptr<=wrptr+1'b1;
      if (fetch) rdptr<=rdptr+1'b1;
      fetch_pending<={fetch_pending[0],fetch};
      if (consume) head_valid<=0;
      if (fetch_pending[1]) head_valid<=1;
      case ({(in_valid && !rst),fetch})
        2'b10: occupancy<=occupancy+1'b1;
        2'b01: occupancy<=occupancy-1'b1;
        default: occupancy<=occupancy;
      endcase
    end
  end

  reg [2:0] layer=0;
  reg [7:0] height=128, row_target=3;
  reg [5:0] groups=8, group=0;
  reg [7:0] nrows=2, issue_index=0;
  reg [13:0] wbase=0, group_base=0, weight_addr=0;
  reg [6:0] table_base=0;
  reg [10:0] input_index=0;
  reg [5:0] pooled_y=0, px=0;
  reg [1:0] corner=0;
  reg [2:0] flush_index=0;
  reg [3:0] timestep=0;
  reg [12:0] read_index=0;
  reg [13:0] load_addr=0, load_count=0;
  reg [3:0] load_lane=0;
  reg [1:0] load_part=0;
  reg [7:0] write_y=0;
  reg [6:0] write_x=0;
  reg [5:0] write_word=0, write_col=0;
  reg [1:0] write_bank=0;
  reg [5:0] center_col=0;
  reg [1:0] center_bank=0;
  reg [5:0] bank_col [0:2];
  reg [3:0] flat_bank=0, block_bank=0;
  reg [7:0] flat_row=0, block_row=0;
  wire [3:0] high_bank = layer==5 ? (flat_bank>=2 ? flat_bank-2 : flat_bank+7) :
                                                   (flat_bank==8 ? 0 : flat_bank+1);
  wire [7:0] high_row = layer==5 ? flat_row+(flat_bank>=2 ? 2 : 1) :
                                                   flat_row+(flat_bank==8);
  reg [63:0] load_low=0;
  reg [31:0] cycles=0;
  reg [6:0] count_neuron=0;
  reg [3:0] pred_class=0, count_class=0, count_vote=0;
  reg [7:0] class_count [0:10];
  reg [7:0] best_count=0;
  reg [3:0] prediction=0;

  wire issue_en = state==ISSUE && !soft_rst;
  wire efire = state==EMIT && !soft_rst;
  wire lfire = state==LOADC && l_valid && !soft_rst;
  assign l_ready = state==LOADC && !soft_rst;
  assign e_data = emit_q;
  wire init_go = !(e_hold && mode==M_CO);
  wire weight_write = consume && state==WDATA && load_part==2;
  wire weight_clear = state==CLEAR && !soft_rst;
  wire [71:0] weight_payload = {head[7:0],load_low};
  wire table_write = consume && state==TDATA && load_part==1;

  wire data_write = consume && state==DATA;
  wire [191:0] bank_bits;
  wire [1535:0] bank_raw;
  wire [143:0] fc_bits;
  wire [6:0] sy={pooled_y,corner[1]}, sx={px,corner[0]};
  wire [6:0] channel=issue_index[6:0];
  genvar b, r;
  generate for (b=0; b<12; b=b+1) begin: input_banks
    (* ram_style = "block" *) reg [15:0] bits_even [0:1407];
    (* ram_style = "block" *) reg [15:0] bits_odd [0:1407];
    reg [15:0] even_int, even_q, odd_int, odd_q;
    reg half_int, half_q;
    wire bank_write=data_write && layer<5 && write_y[1:0]==b/3 && write_bank==b%3;
    wire [10:0] bits_wa={write_col,write_word};
    wire [10:0] bits_ra={bank_col[b%3],channel[6:1]};
    always @(posedge clk) begin
      if (bank_write && layer!=0) begin
        bits_even[bits_wa]<=head[15:0];
        bits_odd[bits_wa]<=head[31:16];
      end
      if (issue_en && layer<5) begin
        even_int<=bits_even[bits_ra]; odd_int<=bits_odd[bits_ra];
        half_int<=channel[0];
      end
      even_q<=even_int; odd_q<=odd_int;
      half_q<=half_int;
    end
    assign bank_bits[b*16 +:16]=half_q ? odd_q : even_q;
    for (r=0; r<4; r=r+1) begin: raw_slices
      (* ram_style = "block" *) reg [31:0] mem [0:171];
      reg [31:0] q_int, q;
      wire [7:0] wa={write_col,write_word[3:2]};
      wire [7:0] ra={bank_col[b%3],issue_index[1:0]};
      always @(posedge clk) begin
        if (bank_write && layer==0 && write_word[1:0]==r) mem[wa]<=head;
        if (issue_en && layer==0) q_int<=mem[ra];
        q<=q_int;
      end
      assign bank_raw[b*128+r*32 +:32]=q;
    end
  end endgenerate
  generate for (b=0; b<9; b=b+1) begin: fc_banks
    (* ram_style = "block" *) reg [15:0] mem [0:227];
    reg [15:0] q_int, q;
    wire write_low=data_write && layer>=5 && flat_bank==b;
    wire write_high=data_write && layer>=5 && high_bank==b;
    always @(posedge clk) begin
      if (write_low || write_high)
        mem[write_low ? flat_row : high_row]<=write_low ? head[15:0] : head[31:16];
      if (issue_en && layer>=5) q_int<=mem[issue_index];
      q<=q_int;
    end
    assign fc_bits[b*16 +:16]=q;
  end endgenerate

  reg [5:0] pipe_valid=0, half_pipe=0;
  reg [1:0] fc_tail_pipe=0;
  reg [3:0] bank_tag [0:8];
  reg [8:0] pad_tag=0;
  reg [127:0] tap_raw [0:8];
  reg [15:0] tap_bits [0:8];
  wire [127:0] selected_raw [0:8];
  wire [15:0] selected_bits [0:8];
  genvar select_tap;
  generate for (select_tap=0; select_tap<9; select_tap=select_tap+1) begin: tap_select
    assign selected_raw[select_tap]=pad_tag[select_tap] ? 128'd0 : bank_raw[bank_tag[select_tap]*128 +:128];
    assign selected_bits[select_tap]=layer<5 ?
      (pad_tag[select_tap] ? 16'd0 : bank_bits[bank_tag[select_tap]*16 +:16]) :
      ((fc_tail_pipe[1] && (layer==5 ? select_tap>=5 : select_tap>=8)) ?
       16'd0 : fc_bits[select_tap*16 +:16]);
  end endgenerate
  integer tap, raw_time;
  reg [1:0] tap_row, tap_col;
  always @(posedge clk) begin
    if (soft_rst) pipe_valid<=0;
    else begin
      pipe_valid<={pipe_valid[4:0],issue_en};
      half_pipe<={half_pipe[4:0],issue_index[0]};
      fc_tail_pipe<={fc_tail_pipe[0],issue_index==nrows-1'b1};
      if (state==INIT) begin
        case (center_bank)
          0: begin bank_col[0]<=center_col; bank_col[1]<=center_col; bank_col[2]<=center_col==0 ? 0 : center_col-1'b1; end
          1: begin bank_col[0]<=center_col; bank_col[1]<=center_col; bank_col[2]<=center_col; end
          2: begin bank_col[0]<=center_col+1'b1; bank_col[1]<=center_col; bank_col[2]<=center_col; end
          default: begin end
        endcase
        for (tap=0; tap<9; tap=tap+1) begin
          tap_row=sy[1:0]+tap/3-1;
          case (tap%3)
            0: tap_col=center_bank==0 ? 2 : center_bank-1'b1;
            1: tap_col=center_bank;
            2: tap_col=center_bank==2 ? 0 : center_bank+1'b1;
          endcase
          case (tap_row)
            0: bank_tag[tap]<=tap_col;
            1: bank_tag[tap]<=3+tap_col;
            2: bank_tag[tap]<=6+tap_col;
            3: bank_tag[tap]<=9+tap_col;
          endcase
          pad_tag[tap]<= (tap/3==0 && sy==0) || (tap/3==2 && sy==height-1'b1) ||
                        (tap%3==0 && sx==0) || (tap%3==2 && sx==height-1'b1);
        end
      end
      if (pipe_valid[1]) for (tap=0; tap<9; tap=tap+1) begin
        tap_bits[tap]<=selected_bits[tap];
        for (raw_time=0; raw_time<8; raw_time=raw_time+1)
          tap_raw[tap][raw_time*16 +:16]<=layer==0 ? selected_raw[tap][raw_time*16 +:16] :
                                                         {15'd0,selected_bits[tap][raw_time]};
      end
    end
  end

  wire [255:0] result_masks;
  wire [511:0] emit_words;
  integer result_addr;
  wire [6:0] next_count_neuron=count_neuron+7'd2;
  always @* begin
    if (state==COUNT) result_addr=next_count_neuron[6:4];
    else if (layer<5) result_addr=(read_index/64)*8+(read_index%64)/8;
    else result_addr=read_index/8;
  end
  wire [255:0] count_masks = result_masks;
  integer pool_addr;
  always @* pool_addr=(layer<5 ? px*8+group : group);

  function [15:0] fwd;
    input signed [31:0] c;
    input signed [6:0] s;
    reg signed [47:0] w;
    reg [3:0] r;
    begin
      r = -s;
      if (!s[6]) w = $signed(c) <<< s[3:0];
`ifdef BUG_CONV
      else w = $signed(c) >>> r;
`else
      else w = ($signed(c) + (48'sd1 <<< (r-1'b1))) >>> r;
`endif
      fwd = (w > 32767) ? 16'h7fff : (w < -32768) ? 16'h8000 : w[15:0];
    end
  endfunction
  function [31:0] inv;
    input signed [15:0] y;
    input signed [6:0] s;
    reg signed [31:0] yw;
    reg [3:0] r;
    begin
      yw = y;
      r = -s;
      if (!s[6] && s != 7'sd0) inv = (yw + (32'sd1 <<< (s[3:0]-1'b1))) >>> s[3:0];
      else inv = yw <<< r;
    end
  endfunction

  genvar lane, t, j;
  generate for (lane=0; lane<16; lane=lane+1) begin: lanes
    wire [71:0] weight_q;
    reg [71:0] wq;
    (* keep_hierarchy = "yes" *) snn_weight_lane weight_memory (
      .clk(clk), .we(weight_clear || (weight_write && load_lane==lane)),
      .wa(load_addr), .wd(weight_clear ? 72'd0 : weight_payload),
      .re(issue_en), .ra(weight_addr), .q(weight_q));
    always @(posedge clk) wq<=weight_q;
    (* ram_style = "distributed" *) reg signed [31:0] biases [0:78];
    (* ram_style = "distributed" *) reg [5:0] shifts [0:78];
    (* ram_style = "block" *) reg [15:0] pool [0:511];
    reg [15:0] old_pool_int, old_pool;
    reg [15:0] result_q_int, result_q;
    reg signed [31:0] bias_q;
    reg [5:0] shift_q;
    reg signed [6:0] cs_q;
    reg signed [35:0] membrane;
    reg signed [31:0] ca, xin;
    reg cav, cbv;
    reg [3:0] cat, cbt;
    reg [15:0] cb, cprev;
    (* ram_style = "distributed" *) reg [31:0] stage [0:7];
    wire co_we = cbv && cbt[0];
    wire li_we = lfire && xi[6:3]==lane;
    wire [3:0] lptr = (state==LIF) ? timestep+1'b1 : 4'd0;
    wire [31:0] lword = stage[lptr[3:1]];
`ifdef BUG_LIFIN
    wire [15:0] lval = lptr[0] ? lword[15:0] : lword[31:16];
`else
    wire [15:0] lval = lptr[0] ? lword[31:16] : lword[15:0];
`endif
    assign emit_words[lane*32 +:32] = stage[xi[2:0]];
    reg [15:0] spikes;
    wire [15:0] store_spikes;
`ifdef PLANTED_BUG
    assign store_spikes=spikes ^ ((layer==6 && lane==0) ? 16'h0001 : 16'h0000);
`else
    assign store_spikes=spikes;
`endif
    wire [31:0] lane_sums [0:15];
    reg signed [31:0] current [0:15];
    integer s;
    reg signed [35:0] added, divided;
    wire signed [31:0] lif_cur = (mode==M_LI) ? xin : current[timestep];
    always @(posedge clk) begin
      result_q_int<=pool[result_addr];
      result_q<=result_q_int;
      if (state==INIT) old_pool_int<=pool[pool_addr];
      old_pool<=old_pool_int;
      if (co_we || li_we) stage[li_we ? xi[2:0] : cbt[3:1]] <= li_we ? l_data : {cb, cprev};
      cav <= state==LIF && mode==M_CO && !soft_rst;
      ca <= current[timestep];
      cat <= timestep;
      cbv <= cav && !soft_rst;
      cb <= fwd(ca, cs_q);
      cbt <= cat;
      if (cbv && !cbt[0]) cprev <= cb;
      xin <= inv(lval, cs_q);
      if (table_write && load_addr%16==lane) begin
        biases[load_addr/16]<=load_low[31:0]; shifts[load_addr/16]<=head[5:0];
      end
      if (!soft_rst) begin
        if (state==INIT) begin
          bias_q<=biases[table_base+group];
          shift_q<=shifts[table_base+group];
          cs_q<={3'd0, (layer==0 ? F_L0[3:0] : F_LN[3:0])} - {1'b0, shifts[table_base+group]};
          for (s=0; s<16; s=s+1) current[s]<=biases[table_base+group];
          membrane<=0; spikes<=0;
        end
        if (pipe_valid[5]) begin
          for (s=0; s<16; s=s+1)
            if (layer!=0 || s/8==half_pipe[5]) current[s]<=current[s]+$signed(lane_sums[layer==0 ? s%8 : s]);
        end
        if (state==LIF) begin
          added=membrane+($signed({{4{lif_cur[31]}},lif_cur}) <<< 4);
          divided=added >>> 1;
          if (divided >= (36'sd16 <<< shift_q)) begin
            spikes[timestep]<=1'b1; membrane<=0;
          end else membrane<=divided;
        end
        if (state==STORE) pool[pool_addr]<= (layer>=5 || corner==0) ? store_spikes : old_pool | store_spikes;
      end
    end
    assign result_masks[lane*16 +:16]=result_q;
    for (t=0; t<16; t=t+1) begin: time_lanes
      wire signed [24:0] products [0:8];
      wire [224:0] next_products;
      reg [224:0] registered_products;
      for (j=0; j<9; j=j+1) begin: taps
        wire signed [7:0] w=$signed(wq[j*8 +:8]);
        wire [15:0] mask=tap_bits[j];
        if (t<8) begin: raw_product
          wire [15:0] raw_value=tap_raw[j][t*16 +:16];
          (* use_dsp = "yes" *) wire signed [24:0] mul=$signed({1'b0,raw_value})*w;
          assign next_products[j*25 +:25]=mul;
        end else begin: binary_product
          assign next_products[j*25 +:25]=mask[t] ? {{17{w[7]}},w} : 25'sd0;
        end
        assign products[j]=$signed(registered_products[j*25 +:25]);
      end
      reg signed [27:0] a,b,c;
      reg signed [31:0] total;
      always @(posedge clk) begin
        if (pipe_valid[2]) registered_products<=next_products;
        if (pipe_valid[3]) begin
          a<=$signed(products[0])+$signed(products[1])+$signed(products[2]);
          b<=$signed(products[3])+$signed(products[4])+$signed(products[5]);
          c<=$signed(products[6])+$signed(products[7])+$signed(products[8]);
        end
        if (pipe_valid[4]) total<=a+b+c;
      end
      assign lane_sums[t]=total;
    end
  end endgenerate

  integer i;
  reg [15:0] count_mask;
  reg [4:0] pc;
  wire visit_end = (state==STORE && mode!=M_CO && !soft_rst) || (efire && xi==7'd127);
  wire [31:0] ws_hi;
  wire [2*QW-1:0] ws_asm;
  generate if (QW > 32) begin: g_ws33
    assign ws_hi = {30'd0, ws_q[2*QW-1], ws_q[QW-1]};
`ifdef BUG_WS33
    assign ws_asm = {ws_w1[31], ws_w1, ws_w0[31], ws_w0};
`else
    assign ws_asm = {head[1], ws_w1, head[0], ws_w0};
`endif
  end else begin: g_ws32
    assign ws_hi = 32'd0;
    assign ws_asm = {ws_w1, ws_w0};
  end endgenerate
  assign s_valid = !mbuf_empty;
  assign s_data = mcnt[1] ? mbuf[15:0] : mbuf[31:16];
  assign s_last = mlastw && mcnt==2'd1;
  wire s_acc = s_valid && s_ready;
  wire pair = co_valid && co_half;
  wire [12:0] pend_next = pend + (consume && cword) - pair;
  wire [1:0] mcnt_next = (consume && state==MSTREAM) ? 2'd2 : mcnt - s_acc;
  always @(posedge clk) begin
    emit_q <= emit_words[xi[6:3]*32 +:32];
    e_valid <= efire;
    if (soft_rst) begin
      mcnt<=0; mbuf_empty<=1'b1; pend<=0; pend_zero<=1'b1; co_half<=1'b0; ws_have<=1'b0; ws_wait<=1'b0;
    end else begin
      mcnt<=mcnt_next; mbuf_empty<=mcnt_next==2'd0;
      if (consume && state==MSTREAM) begin mbuf<=head; mlastw<=mwords==14'd1; end
      pend<=pend_next; pend_zero<=pend_next==13'd0;
      if (co_valid) begin co_half<=!co_half; if (!co_half) co_hold<=co_data; end
      if (consume && state==WSRDATA && ws_part==2'd2) ws_have<=1'b0;
      if (ws_wait && ws_rvalid) begin ws_q<=ws_rdata; ws_have<=1'b1; ws_wait<=1'b0; end
      if (consume && state==WSRDATA && ws_part==2'd2 && ws_cnt!=12'd1) ws_wait<=1'b1;
      if (consume && state==WSCOUNT && ws_rd) ws_wait<=1'b1;
    end
  end
  wire active_cycle = (consume && (state==DATA || state==READ)) || efire || lfire ||
    (state>=INIT && state<=STORE && (state!=INIT || init_go)) || state==COUNT || state==PRED;
  always @(posedge clk) begin
    out_valid<=0;
    mrst<=1'b0;
    ws_en<=1'b0;
    if (soft_rst) begin
      state<=CMD; cycles<=0; input_index<=0; read_index<=0;
    end else begin
      if (active_cycle) cycles<=cycles+1'b1;
      if (consume) begin
        out_valid<=!cword; out_data<=0;
        case (state)
          CMD: case (head[31:28])
            5: begin s_kind<=head[27:26]; s_lane<=head[25:23]; s_slot<=head[22:18]; s_t<=head[17:14]; mwords<=head[13:0]; state<=MSTREAM; end
            6, 7: begin ws_sel<=head[27]; ws_lane<=head[26:24]; ws_ptr<=head[11:0]; ws_rd<=head[28]; state<=WSCOUNT; end
            8: begin mrst<=1'b1; state<=CMD; end
            1: begin load_lane<=head[27:24]; load_addr<=head[13:0]; state<=WCOUNT; end
            2: begin load_addr<=head[10:0]; state<=TCOUNT; end
            4: begin load_addr<=head[13:0]; state<=CCOUNT; end
            3: begin
              layer<=head[2:0]; input_index<=0; cycles<=0;
              mode<=(head[2:0]<5 && head[5:4]!=2'd3) ? head[5:4] : M_NORMAL;
              state<=(head[2:0]<5 && head[5:4]==M_LI) ? INIT : DATA;
              pooled_y<=0; px<=0; corner<=0; group<=0; read_index<=0; row_target<=3;
              write_y<=0; write_x<=0; write_word<=0; write_col<=0; write_bank<=0;
              center_col<=0; center_bank<=0;
              flat_bank<=0; flat_row<=0; block_bank<=0; block_row<=0;
              for (i=0; i<11; i=i+1) class_count[i]<=0;
              prediction<=0; best_count<=0;
              case (head[2:0])
                0: begin height<=128; groups<=8; nrows<=2; wbase<=0; group_base<=0; table_base<=0; end
                1: begin height<=64; groups<=8; nrows<=128; wbase<=16; group_base<=16; table_base<=8; end
                2: begin height<=32; groups<=8; nrows<=128; wbase<=1040; group_base<=1040; table_base<=16; end
                3: begin height<=16; groups<=8; nrows<=128; wbase<=2064; group_base<=2064; table_base<=24; end
                4: begin height<=8; groups<=8; nrows<=128; wbase<=3088; group_base<=3088; table_base<=32; end
                5: begin height<=1; groups<=32; nrows<=228; wbase<=4112; group_base<=4112; table_base<=40; end
                6: begin height<=1; groups<=7; nrows<=57; wbase<=11408; group_base<=11408; table_base<=72; end
                default: state<=CMD;
              endcase
            end
            default: state<=CMD;
          endcase
          WCOUNT: begin load_count<=head; load_part<=0; state<=WDATA; end
          TCOUNT: begin load_count<=head; load_part<=0; state<=TDATA; end
          CCOUNT: begin load_count<=head; state<=CLEAR; end
          WDATA: begin
            if (load_part==0) begin load_low[31:0]<=head; load_part<=1; end
            else if (load_part==1) begin load_low[63:32]<=head; load_part<=2; end
            else begin
              load_part<=0; load_addr<=load_addr+1; load_count<=load_count-1;
              if (load_count==1) state<=CMD;
            end
          end
          TDATA: begin
            if (load_part==0) begin load_low[31:0]<=head; load_part<=1; end
            else begin
              load_part<=0; load_addr<=load_addr+1; load_count<=load_count-1;
              if (load_count==1) state<=CMD;
            end
          end
          DATA: begin
            input_index<=input_index+1;
            if (layer<5) begin
              if (write_word==(layer==0 ? 15 : 63)) begin
                write_word<=0;
                if (write_x==height-1'b1) begin
                  write_x<=0; write_col<=0; write_bank<=0; write_y<=write_y+1'b1;
                end else begin
                  write_x<=write_x+1'b1;
                  if (write_bank==2) begin write_bank<=0; write_col<=write_col+1'b1; end
                  else write_bank<=write_bank+1'b1;
                end
              end else write_word<=write_word+1'b1;
            end else if (layer==5) begin
              if (input_index[5:0]==63) begin
                if (block_bank==8) begin
                  block_bank<=0; flat_bank<=0;
                  block_row<=block_row+1'b1; flat_row<=block_row+1'b1;
                end else begin
                  block_bank<=block_bank+1'b1; flat_bank<=block_bank+1'b1; flat_row<=block_row;
                end
              end else if (flat_bank>=4) begin flat_bank<=flat_bank-4; flat_row<=flat_row+4; end
              else begin flat_bank<=flat_bank+5; flat_row<=flat_row+3; end
            end else begin
              if (flat_bank>=7) begin flat_bank<=flat_bank-7; flat_row<=flat_row+1'b1; end
              else flat_bank<=flat_bank+2;
            end
            if ((layer<5 && write_word==(layer==0 ? 15 : 63) && write_x==height-1'b1 && write_y==row_target-1'b1) ||
                (layer==5 && input_index==1023) || (layer==6 && input_index==255)) begin
              state<=INIT; issue_index<=0; group<=0; px<=0; corner<=0; group_base<=wbase;
              center_col<=0; center_bank<=0;
            end
          end
          MSTREAM: begin
            mwords<=mwords-1'b1;
            if (mwords==14'd1) state<=CMD;
          end
          WSCOUNT: begin
            ws_cnt<=head[11:0]; ws_part<=0;
            if (ws_rd) begin
              state<=WSRDATA; ws_en<=1'b1; ws_we<=1'b0; ws_addr<=ws_ptr; ws_ptr<=ws_ptr+1'b1;
            end else state<=WSWDATA;
          end
          WSWDATA: begin
            if (ws_part==2'd0) begin ws_w0<=head; ws_part<=2'd1; end
            else if (ws_part==2'd1) begin ws_w1<=head; ws_part<=2'd2; end
            else begin
              ws_part<=2'd0; ws_en<=1'b1; ws_we<=1'b1; ws_addr<=ws_ptr; ws_ptr<=ws_ptr+1'b1; ws_wdata<=ws_asm;
              ws_cnt<=ws_cnt-1'b1;
              if (ws_cnt==12'd1) state<=CMD;
            end
          end
          WSRDATA: begin
            if (ws_part==2'd0) begin out_data<=ws_q[31:0]; ws_part<=2'd1; end
            else if (ws_part==2'd1) begin out_data<=ws_q[QW+31:QW]; ws_part<=2'd2; end
            else begin
              out_data<=ws_hi; ws_part<=2'd0; ws_cnt<=ws_cnt-1'b1;
              if (ws_cnt==12'd1) state<=CMD;
              else begin ws_en<=1'b1; ws_we<=1'b0; ws_addr<=ws_ptr; ws_ptr<=ws_ptr+1'b1; end
            end
          end
          READ: begin
            read_index<=read_index+1;
            if (layer<5) begin
              if (read_index < height/2*64) begin
                out_data<=result_masks[(read_index%8)*32 +:32];
                if (read_index+1==height/2*64 && pooled_y+1<height/2) begin
                  pooled_y<=pooled_y+1; row_target<= (2*pooled_y+5<height ? 2*pooled_y+5 : height);
                  read_index<=0;
                  if (mode==M_LI) begin
                    state<=INIT; group<=0; px<=0; corner<=0; group_base<=wbase; center_col<=0; center_bank<=0;
                  end else state<=DATA;
                end
              end else begin out_data<=cycles+1'b1; state<=CMD; end
            end else if (read_index < (layer==5 ? 256 : 55))
              out_data<=result_masks[(read_index%8)*32 +:32];
            else if (layer==6 && read_index<66) out_data<={24'd0,class_count[read_index-55]};
            else if (layer==6 && read_index==66) out_data<={28'd0,prediction};
            else begin out_data<=cycles+1'b1; state<=CMD; end
          end
          default: state<=CMD;
        endcase
      end
      case (state)
        CLEAR: begin
          load_addr<=load_addr+1; load_count<=load_count-1;
          if (load_count==1) state<=CMD;
        end
        INIT: if (init_go) begin state<=(mode==M_LI) ? LOADC : ISSUE; issue_index<=0; weight_addr<=group_base; xi<=0; end
        EMIT: xi<=xi+1'b1;
        LOADC: if (l_valid) begin
          xi<=xi+1'b1;
          if (xi==7'd127) begin state<=LIF; timestep<=0; end
        end
        ISSUE: begin
          issue_index<=issue_index+1;
          if (layer!=0 || issue_index[0]) weight_addr<=weight_addr+1'b1;
          if (issue_index+1==(layer==0 ? 4 : nrows)) begin state<=FLUSH; flush_index<=0; end
        end
        FLUSH: begin
          flush_index<=flush_index+1;
          if (flush_index==5) begin state<=LIF; timestep<=0; end
        end
        LIF: begin timestep<=timestep+1; if (timestep==15) state<=STORE; end
        STORE: if (mode==M_CO) state<=EMIT;
        default: begin end
      endcase
      if (visit_end) begin
        begin
          if (group+1<groups) begin group<=group+1; group_base<=group_base+nrows; state<=INIT; end
          else if (layer<5 && corner<3) begin
            group<=0; group_base<=wbase; corner<=corner+1'b1; state<=INIT;
            if (corner==1) begin
              if (center_bank==0) begin center_bank<=2; center_col<=center_col-1'b1; end
              else center_bank<=center_bank-1'b1;
            end else begin
              if (center_bank==2) begin center_bank<=0; center_col<=center_col+1'b1; end
              else center_bank<=center_bank+1'b1;
            end
          end
          else if (layer<5 && px+1<height/2) begin
            group<=0; group_base<=wbase; corner<=0; px<=px+1'b1; state<=INIT;
            if (center_bank==2) begin center_bank<=0; center_col<=center_col+1'b1; end
            else center_bank<=center_bank+1'b1;
          end
          else if (mode==M_CO) begin
            if (pooled_y+1<height/2) begin
              pooled_y<=pooled_y+1; row_target<= (2*pooled_y+5<height ? 2*pooled_y+5 : height); state<=DATA;
            end else begin read_index<=height/2*64; state<=READ; end
          end
          else begin
            read_index<=0;
            if (layer==6) begin count_neuron<=0; count_class<=0; count_vote<=0; state<=COUNT; end
            else state<=READ;
          end
        end
      end
      case (state)
        COUNT: begin
          count_mask=count_masks[count_neuron[3:0]*16 +:16];
          pc=({4'd0,count_mask[0]}+count_mask[1]) + ({4'd0,count_mask[2]}+count_mask[3]) +
             ({4'd0,count_mask[4]}+count_mask[5]) + ({4'd0,count_mask[6]}+count_mask[7]) +
             ({4'd0,count_mask[8]}+count_mask[9]) + ({4'd0,count_mask[10]}+count_mask[11]) +
             ({4'd0,count_mask[12]}+count_mask[13]) + ({4'd0,count_mask[14]}+count_mask[15]);
          class_count[count_class]<=class_count[count_class]+pc;
          if (count_vote==9) begin count_vote<=0; count_class<=count_class+1'b1; end
          else count_vote<=count_vote+1'b1;
          count_neuron<=count_neuron+1;
          if (count_neuron==109) begin state<=PRED; pred_class<=0; best_count<=0; prediction<=0; end
        end
        PRED: begin
          if (class_count[pred_class]>best_count) begin best_count<=class_count[pred_class]; prediction<=pred_class; end
          pred_class<=pred_class+1;
          if (pred_class==10) state<=READ;
        end
        default: begin end
      endcase
      if (pair) begin out_valid<=1'b1; out_data<={co_data, co_hold}; end
    end
    if (rst) out_valid<=0;
  end
`ifndef SYNTHESIS
  reg [1:0] previous_read=0;
  always @(posedge clk) begin
    previous_read<={previous_read[0],consume && state==READ};
    if (consume && state==READ && (|previous_read))
      $fatal(1,"FPGA_VIVADO_FAIL pool BRAM prefetch requires three-clock READ spacing");
    if (!soft_rst && in_valid && !rst && occupancy==4096 && !fetch)
      $fatal(1,"FPGA_VIVADO_FAIL FIFO overflow");
    if (consume && state==WCOUNT && (head==0 || load_addr+head>11807))
      $fatal(1,"FPGA_VIVADO_FAIL invalid weight load");
    if (consume && state==TCOUNT && (head==0 || load_addr+head>1262))
      $fatal(1,"FPGA_VIVADO_FAIL invalid table load");
    if (consume && state==CCOUNT && (head==0 || head>11807 || load_addr+head>11807))
      $fatal(1,"FPGA_VIVADO_FAIL invalid weight clear");
  end
`endif
endmodule

(* keep_hierarchy = "yes" *)
module snn_weight_lane (
  input wire clk, we, re,
  input wire [13:0] wa, ra,
  input wire [71:0] wd,
  output reg [71:0] q
);
  (* ram_style = "ultra" *) reg [71:0] weights [0:11806];
  reg [71:0] read_stage;
  reg read_valid;
  always @(posedge clk) if (we) weights[wa]<=wd;
  always @(posedge clk) begin
    read_valid<=re;
    if (re) read_stage<=weights[ra];
    if (read_valid) q<=read_stage;
  end
endmodule
`default_nettype wire
