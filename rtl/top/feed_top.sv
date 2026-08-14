`default_nettype none

module feed_top #(
    parameter logic [47:0] MCAST_MAC = 48'h01_00_5E_36_0C_6F,
    parameter logic [31:0] MCAST_IP = 32'hE9_36_0C_6F,
    parameter logic [15:0] FEED_PORT = 16'd26477
)(
    input wire logic clk,
    input wire logic rst,
    input wire logic in_valid,
    input wire logic [63:0] in_data,
    input wire logic [7:0] in_keep,
    input wire logic in_last,
    input wire logic in_fcs_ok,
    output logic rec_valid,
    output logic [7:0] rec_type,
    output logic [15:0] rec_locate,
    output logic [47:0] rec_time,
    output logic [63:0] rec_seq,
    output logic [63:0] rec_ref,
    output logic [63:0] rec_ref2,
    output logic [31:0] rec_shares,
    output logic [31:0] rec_price,
    output logic rec_side,
    output logic [63:0] rec_stock,
    output logic rec_err,
    output logic drop_pulse,
    output logic pkt_bad
);

    logic hs_valid, hs_last, hs_fcs_ok;
    logic [63:0] hs_data;
    logic [7:0] hs_keep;

    logic mold_valid, mold_last, mold_fcs_ok;
    logic [63:0] mold_data;
    logic [7:0] mold_keep;

    logic raw_valid, raw_start, raw_last;
    logic [127:0] raw_data;
    logic [15:0] raw_keep;
    logic [15:0] raw_len;
    logic [63:0] raw_seq;

    logic msg_valid, msg_start, msg_last;
    logic [127:0] msg_data;
    logic [15:0] msg_keep;
    logic [15:0] msg_len;
    logic [63:0] msg_seq;

    logic parse_valid, parse_side, parse_err;
    logic [7:0] parse_type;
    logic [15:0] parse_locate;
    logic [47:0] parse_time;
    logic [63:0] parse_seq, parse_ref, parse_ref2, parse_stock;
    logic [31:0] parse_shares, parse_price;

    // A 10G MAC only reports a bad frame with tuser on the final beat, by which
    // point the frame's records have already been emitted. Suppressing them would
    // cost a frame of buffering, ~1.17 us at 10 Gbps against a 32 ns parse, so the
    // records go out unconditionally and pkt_bad is left as a status output. Bad
    // FCS is a 1e-12 event on a working link.

    header_strip #(
        .MCAST_MAC(MCAST_MAC),
        .MCAST_IP(MCAST_IP),
        .FEED_PORT(FEED_PORT)
    ) u_header_strip (
        .clk(clk),
        .rst(rst),
        .in_valid(in_valid),
        .in_data(in_data),
        .in_keep(in_keep),
        .in_last(in_last),
        .in_fcs_ok(in_fcs_ok),
        .out_valid(hs_valid),
        .out_data(hs_data),
        .out_keep(hs_keep),
        .out_last(hs_last),
        .out_fcs_ok(hs_fcs_ok),
        .drop_pulse(drop_pulse)
    );

    mold_deframe #(
        .IN_BYTES(8)
    ) u_mold_deframe (
        .clk(clk),
        .rst(rst),
        .in_valid(mold_valid),
        .in_data(mold_data),
        .in_keep(mold_keep),
        .in_last(mold_last),
        .in_fcs_ok(mold_fcs_ok),
        .msg_valid(raw_valid),
        .msg_data(raw_data),
        .msg_keep(raw_keep),
        .msg_start(raw_start),
        .msg_last(raw_last),
        .msg_len(raw_len),
        .msg_seq(raw_seq),
        .pkt_bad(pkt_bad)
    );

    itch_parse u_itch_parse (
        .clk(clk),
        .rst(rst),
        .msg_valid(msg_valid),
        .msg_data(msg_data),
        .msg_keep(msg_keep),
        .msg_start(msg_start),
        .msg_last(msg_last),
        .msg_len(msg_len),
        .msg_seq(msg_seq),
        .rec_valid(parse_valid),
        .rec_type(parse_type),
        .rec_locate(parse_locate),
        .rec_time(parse_time),
        .rec_seq(parse_seq),
        .rec_ref(parse_ref),
        .rec_ref2(parse_ref2),
        .rec_shares(parse_shares),
        .rec_price(parse_price),
        .rec_side(parse_side),
        .rec_stock(parse_stock),
        .rec_err(parse_err)
    );

    symbol_filter u_symbol_filter (
        .clk(clk),
        .rst(rst),
        .rec_valid(parse_valid),
        .rec_type(parse_type),
        .rec_locate(parse_locate),
        .rec_time(parse_time),
        .rec_seq(parse_seq),
        .rec_ref(parse_ref),
        .rec_ref2(parse_ref2),
        .rec_shares(parse_shares),
        .rec_price(parse_price),
        .rec_side(parse_side),
        .rec_stock(parse_stock),
        .out_valid(rec_valid),
        .out_type(rec_type),
        .out_locate(rec_locate),
        .out_time(rec_time),
        .out_seq(rec_seq),
        .out_ref(rec_ref),
        .out_ref2(rec_ref2),
        .out_shares(rec_shares),
        .out_price(rec_price),
        .out_side(rec_side),
        .out_stock(rec_stock)
    );

    always_ff @(posedge clk) begin
        if (rst) begin
            mold_valid <= 1'b0;
            mold_last <= 1'b0;
            msg_valid <= 1'b0;
            msg_start <= 1'b0;
            msg_last <= 1'b0;
            rec_err <= 1'b0;
        end else begin
            mold_valid <= hs_valid;
            mold_last <= hs_last;
            msg_valid <= raw_valid;
            msg_start <= raw_start;
            msg_last <= raw_last;
            rec_err <= parse_err;
        end
        mold_data <= hs_data;
        mold_keep <= hs_keep;
        mold_fcs_ok <= hs_fcs_ok;
        msg_data <= raw_data;
        msg_keep <= raw_keep;
        msg_len <= raw_len;
        msg_seq <= raw_seq;
    end

endmodule

`default_nettype wire
