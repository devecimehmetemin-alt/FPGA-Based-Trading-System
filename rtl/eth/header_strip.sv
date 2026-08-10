`default_nettype none

module header_strip #(
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
    output logic out_valid,
    output logic [63:0] out_data,
    output logic [7:0] out_keep,
    output logic out_last,
    output logic out_fcs_ok,
    output logic drop_pulse
);

    localparam logic [31:0] MAC_W0 = {MCAST_MAC[23:16], MCAST_MAC[31:24], MCAST_MAC[39:32], MCAST_MAC[47:40]};
    localparam logic [15:0] MAC_W1 = {MCAST_MAC[7:0], MCAST_MAC[15:8]};
    localparam logic [15:0] ETYPE_W = 16'h0008;
    localparam logic [7:0] VER_IHL = 8'h45;
    localparam logic [7:0] PROTO = 8'd17;
    localparam logic [15:0] IP_A = {MCAST_IP[23:16], MCAST_IP[31:24]};
    localparam logic [15:0] IP_B = {MCAST_IP[7:0], MCAST_IP[15:8]};
    localparam logic [15:0] PORT_W = {FEED_PORT[7:0], FEED_PORT[15:8]};
    localparam int W_LOAD = 5;
    localparam int W_FORWARD = 6;

    function automatic logic [3:0] keep_to_n(input logic [7:0] k);
        case (k)
            8'b00000001: keep_to_n = 4'd1;
            8'b00000011: keep_to_n = 4'd2;
            8'b00000111: keep_to_n = 4'd3;
            8'b00001111: keep_to_n = 4'd4;
            8'b00011111: keep_to_n = 4'd5;
            8'b00111111: keep_to_n = 4'd6;
            8'b01111111: keep_to_n = 4'd7;
            default: keep_to_n = 4'd8;
        endcase
    endfunction

    function automatic logic [7:0] n_to_keep(input logic [3:0] n);
        case (n)
            4'd1: n_to_keep = 8'b00000001;
            4'd2: n_to_keep = 8'b00000011;
            4'd3: n_to_keep = 8'b00000111;
            4'd4: n_to_keep = 8'b00001111;
            4'd5: n_to_keep = 8'b00011111;
            4'd6: n_to_keep = 8'b00111111;
            4'd7: n_to_keep = 8'b01111111;
            default: n_to_keep = 8'b11111111;
        endcase
    endfunction

    logic [4:0] wcnt;
    logic accept;
    logic ip_part;
    logic [63:0] prev;
    logic flush;
    logic [3:0] flush_bytes;
    logic flush_fcs;
    logic [3:0] n_in, avail;

    assign n_in = keep_to_n(in_keep);
    assign avail = 4'd6 + n_in;
    assign drop_pulse = in_valid & in_last & ~accept;

    always_ff @(posedge clk) begin
        if (rst) begin
            wcnt <= '0;
            accept <= 1'b1;
        end else if (in_valid) begin
            prev <= in_data;

            case (wcnt)
                5'd0: begin
                    if (in_data[31:0] != MAC_W0) accept <= 1'b0;
                    if (in_data[47:32] != MAC_W1) accept <= 1'b0;
                end
                5'd1: begin
                    if (in_data[47:32] != ETYPE_W) accept <= 1'b0;
                    if (in_data[55:48] != VER_IHL) accept <= 1'b0;
                end
                5'd2: begin
                    if ((in_data[39:32] & 8'h3F) != 8'h00) accept <= 1'b0;
                    if (in_data[47:40] != 8'h00) accept <= 1'b0;
                    if (in_data[63:56] != PROTO) accept <= 1'b0;
                end
                5'd3: ip_part <= (in_data[63:48] == IP_A);
                5'd4: begin
                    if (!(ip_part && in_data[15:0] == IP_B)) accept <= 1'b0;
                    if (in_data[47:32] != PORT_W) accept <= 1'b0;
                end
                default: ;
            endcase

            if (in_last) begin
                wcnt <= '0;
                accept <= 1'b1;
            end else if (wcnt != 5'd31) begin
                wcnt <= wcnt + 1'b1;
            end
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            flush <= 1'b0;
        end else begin
            flush <= 1'b0;
            if (in_valid & accept & in_last & (wcnt >= W_FORWARD) & (avail > 4'd8)) begin
                flush <= 1'b1;
                flush_bytes <= avail - 4'd8;
                flush_fcs <= in_fcs_ok;
            end
        end
    end

    always_comb begin
        out_valid = 1'b0;
        out_data = {in_data[15:0], prev[63:16]};
        out_keep = 8'b11111111;
        out_last = 1'b0;
        out_fcs_ok = in_fcs_ok;

        if (flush) begin
            out_valid = 1'b1;
            out_data = {16'h0, prev[63:16]};
            out_keep = n_to_keep(flush_bytes);
            out_last = 1'b1;
            out_fcs_ok = flush_fcs;
        end
        else if (in_valid & accept) begin
            if ((wcnt == W_LOAD) & in_last) begin
                if (n_in > 4'd2) begin
                    out_valid = 1'b1;
                    out_data = {16'h0, in_data[63:16]};
                    out_keep = n_to_keep(n_in - 4'd2);
                    out_last = 1'b1;
                end
            end else if (wcnt >= W_FORWARD) begin
                out_valid = 1'b1;
                if (in_last & (avail <= 4'd8)) begin
                    out_keep = n_to_keep(avail);
                    out_last = 1'b1;
                end
            end
        end
    end

endmodule

`default_nettype wire
