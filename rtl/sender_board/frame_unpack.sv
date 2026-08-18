`default_nettype none

// Splits the DDR record stream into paced frames on the MAC's 64 bit interface.

module frame_unpack (
    input wire logic clk,
    input wire logic rst,
    input wire logic in_valid,
    input wire logic [63:0] in_data,
    output logic in_ready,
    output logic pace_req,
    output logic [31:0] pace_period,
    input wire logic pace_grant,
    output logic out_valid,
    output logic [63:0] out_data,
    output logic [7:0] out_keep,
    output logic out_last,
    input wire logic out_ready,
    output logic frame_pulse,
    output logic underrun
);

    localparam logic HDR = 1'b0;
    localparam logic BODY = 1'b1;

    logic state;
    logic [12:0] beats_left;
    logic [7:0] tail_keep;
    logic [15:0] hdr_len;
    logic [12:0] hdr_beats;
    logic [7:0] hdr_keep;
    logic body_fire, hdr_fire, last_beat;

    assign hdr_len = in_data[15:0];
    assign hdr_beats = 13'((hdr_len + 16'd7) >> 3);
    assign hdr_keep = (hdr_len[2:0] == 3'd0) ? 8'hFF : 8'((8'd1 << hdr_len[2:0]) - 8'd1);

    assign pace_period = in_data[63:32];
    assign pace_req = (state == HDR) & in_valid & (hdr_len != 16'd0);

    assign last_beat = (beats_left == 13'd1);
    assign in_ready = (state == HDR) ? ((hdr_len == 16'd0) | pace_grant) : out_ready;

    assign out_valid = (state == BODY) & in_valid;
    assign out_data = in_data;
    assign out_keep = last_beat ? tail_keep : 8'hFF;
    assign out_last = last_beat;

    assign hdr_fire = (state == HDR) & in_valid & in_ready & (hdr_len != 16'd0);
    assign body_fire = (state == BODY) & in_valid & out_ready;

    assign frame_pulse = body_fire & last_beat;
    assign underrun = (state == BODY) & ~in_valid;

    always_ff @(posedge clk) begin
        if (rst) begin
            state <= HDR;
            beats_left <= '0;
            tail_keep <= 8'hFF;
        end else if (hdr_fire) begin
            state <= BODY;
            beats_left <= hdr_beats;
            tail_keep <= hdr_keep;
        end else if (body_fire) begin
            beats_left <= beats_left - 13'd1;
            if (last_beat) state <= HDR;
        end
    end

endmodule

`default_nettype wire
