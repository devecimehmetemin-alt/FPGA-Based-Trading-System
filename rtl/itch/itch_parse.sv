`default_nettype none

module itch_parse (
    input wire logic clk,
    input wire logic rst,
    input wire logic msg_valid,
    input wire logic [127:0] msg_data,
    input wire logic [15:0] msg_keep,
    input wire logic msg_start,
    input wire logic msg_last,
    input wire logic [15:0] msg_len,
    input wire logic [63:0] msg_seq,
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
    output logic rec_err
);

    // ITCH 5.0: type[1] locate[2] track[2] time[6] then a fixed body per type.
    // The buffer is 40 bytes, the length of F, the longest message kept.
    // msg_buf_rev is msg_buf byte-reversed, so a big-endian field at message
    // offset f width w is msg_buf_rev[8*(40-f-w) +: 8*w].

    logic [4:0] beat_bytes; // message bytes carried by this beat, 0 to 16
    logic [5:0] byte_base; // registered, lane 0 offset of the next beat
    logic [5:0] lane0_offset; // message offset of lane 0 on this beat
    logic [7:0] msg_type, msg_type_live; // latched, and valid on the start beat too
    logic type_wanted; // the type is one the book acts on
    logic [15:0] expect_len; // the type's fixed length
    logic len_match;
    logic [63:0] seq_held; // msg_seq advances at msg_last, so hold it
    logic [319:0] msg_buf, msg_buf_rev;

    assign msg_type_live = msg_start ? msg_data[7:0] : msg_type;
    assign lane0_offset = msg_start ? '0 : byte_base;
    assign len_match = (msg_len == expect_len);

    always_comb begin
        beat_bytes = '0;
        for (int lane = 0; lane < 16; lane++)
            beat_bytes = beat_bytes + 5'(msg_keep[lane]);
    end

    always_comb begin
        type_wanted = 1'b1;
        expect_len = 16'd0;
        case (msg_type_live)
            8'h41: expect_len = 16'd36; // A add order
            8'h46: expect_len = 16'd40; // F add order with attribution
            8'h45: expect_len = 16'd31; // E order executed
            8'h43: expect_len = 16'd36; // C order executed with price
            8'h58: expect_len = 16'd23; // X order cancel
            8'h44: expect_len = 16'd19; // D order delete
            8'h55: expect_len = 16'd35; // U order replace
            8'h52: expect_len = 16'd39;
            default: type_wanted = 1'b0;
        endcase
    end

    always_comb
        for (int byte_idx = 0; byte_idx < 40; byte_idx++)
            msg_buf_rev[8*byte_idx +: 8] = msg_buf[8*(39-byte_idx) +: 8];

    always_comb begin
        rec_type = msg_type;
        rec_seq = seq_held;
        rec_locate = msg_buf_rev[8*37 +: 16]; // offset 1 width 2
        rec_time = msg_buf_rev[8*29 +: 48]; // offset 5 width 6
        rec_ref = msg_buf_rev[8*21 +: 64]; // offset 11 width 8
        rec_ref2 = '0;
        rec_shares = '0;
        rec_price = '0;
        rec_side = 1'b0;
        rec_stock = '0;
        case (msg_type)
            8'h41, 8'h46: begin
                rec_side = (msg_buf[8*19 +: 8] == 8'h42); // 'B'
                rec_shares = msg_buf_rev[8*16 +: 32]; // offset 20 width 4
                rec_stock = msg_buf_rev[8*8 +: 64]; // offset 24 width 8
                rec_price = msg_buf_rev[8*4 +: 32]; // offset 32 width 4
            end
            8'h45, 8'h58: rec_shares = msg_buf_rev[8*17 +: 32]; // offset 19 width 4
            8'h43: begin
                rec_shares = msg_buf_rev[8*17 +: 32]; // offset 19 width 4
                rec_price = msg_buf_rev[8*4 +: 32]; // offset 32 width 4
            end
            8'h55: begin
                rec_ref2 = msg_buf_rev[8*13 +: 64]; // offset 19 width 8
                rec_shares = msg_buf_rev[8*9 +: 32]; // offset 27 width 4
                rec_price = msg_buf_rev[8*5 +: 32]; // offset 31 width 4
            end
            8'h52: rec_stock = msg_buf_rev[8*21 +: 64];
        endcase
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            byte_base <= '0;
            rec_valid <= 1'b0;
            rec_err <= 1'b0;
        end else begin
            rec_valid <= msg_valid & msg_last & type_wanted & len_match;
            rec_err <= msg_valid & msg_last & type_wanted & ~len_match;
            if (msg_valid)
                byte_base <= msg_start ? 6'(beat_bytes) : byte_base + 6'(beat_bytes);
        end
        if (msg_valid & msg_start) begin
            msg_type <= msg_data[7:0];
            seq_held <= msg_seq;
        end
        if (msg_valid & type_wanted)
            for (int byte_idx = 0; byte_idx < 40; byte_idx++)
                if (byte_idx >= int'(lane0_offset) && byte_idx < int'(lane0_offset) + int'(beat_bytes))
                    msg_buf[8*byte_idx +: 8] <= msg_data[8*(byte_idx - int'(lane0_offset)) +: 8];
    end

endmodule

`default_nettype wire