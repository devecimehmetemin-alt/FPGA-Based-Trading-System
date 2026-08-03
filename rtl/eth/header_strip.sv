`default_nettype none

module header_strip #(
    parameter logic [47:0] MCAST_MAC = 48'h01_00_5E_36_0C_6F,
    parameter logic [31:0] MCAST_IP = 32'hE9_36_0C_6F,
    parameter logic [15:0] FEED_PORT = 16'd26477
)(
    input wire logic clk,
    input wire logic rst,
    input wire logic in_valid,
    input wire logic [31:0] in_data,
    input wire logic [3:0] in_keep,
    input wire logic in_last,
    input wire logic in_fcs_ok,
    output logic out_valid,
    output logic [31:0] out_data,
    output logic [3:0] out_keep,
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
    localparam int W_LOAD = 10;
    localparam int W_FORWARD = 11;

    function automatic logic [2:0] keep_to_n(input logic [3:0] k);
        case (k)
            4'b0001: keep_to_n = 3'd1;
            4'b0011: keep_to_n = 3'd2;
            4'b0111: keep_to_n = 3'd3;
            default: keep_to_n = 3'd4;
        endcase
    endfunction

    function automatic logic [3:0] n_to_keep(input logic [2:0] n);
        case (n)
            3'd1: n_to_keep = 4'b0001;
            3'd2: n_to_keep = 4'b0011;
            3'd3: n_to_keep = 4'b0111;
            default: n_to_keep = 4'b1111;
        endcase
    endfunction

    logic [4:0] wcnt;
    logic accept;
    logic ip_part;
    logic [31:0] prev;
    logic flush;
    logic [2:0] flush_bytes;
    logic flush_fcs;
    logic [2:0] n_in, avail;

    assign n_in = keep_to_n(in_keep);
    assign avail = 3'd2 + n_in;
    assign drop_pulse = in_valid & in_last & ~accept;

    always_ff @(posedge clk) begin
        if (rst) begin
            wcnt <= '0;
            accept <= 1'b1;
        end else if (in_valid) begin
            prev <= in_data;

            case (wcnt)
                5'd0: if (in_data != MAC_W0) accept <= 1'b0;
                5'd1: if (in_data[15:0] != MAC_W1) accept <= 1'b0;
                5'd3: begin
                    if (in_data[15:0] != ETYPE_W) accept <= 1'b0;
                    if (in_data[23:16] != VER_IHL) accept <= 1'b0;
                end
                5'd5: begin
                    if ((in_data[7:0] & 8'h3F) != 8'h00) accept <= 1'b0;
                    if (in_data[15:8] != 8'h00) accept <= 1'b0;
                    if (in_data[31:24] != PROTO) accept <= 1'b0;
                end
                5'd7: ip_part <= (in_data[31:16] == IP_A);
                5'd8: if (!(ip_part && in_data[15:0] == IP_B)) accept <= 1'b0;
                5'd9: if (in_data[15:0] != PORT_W) accept <= 1'b0;
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
            if (in_valid & accept & in_last & (wcnt >= W_FORWARD) & (avail > 3'd4)) begin
                flush <= 1'b1;
                flush_bytes <= avail - 3'd4;
                flush_fcs <= in_fcs_ok;
            end
        end
    end

    always_comb begin
        out_valid = 1'b0;
        out_data = {in_data[15:0], prev[31:16]};
        out_keep = 4'b1111;
        out_last = 1'b0;
        out_fcs_ok = in_fcs_ok;

        if (flush) begin
            out_valid = 1'b1;
            out_data = {16'h0, prev[31:16]};
            out_keep = n_to_keep(flush_bytes);
            out_last = 1'b1;
            out_fcs_ok = flush_fcs;
        end
        else if (in_valid & accept) begin
            if ((wcnt == W_LOAD) & in_last) begin
                if (n_in > 3'd2) begin
                    out_valid = 1'b1;
                    out_data = {16'h0, in_data[31:16]};
                    out_keep = n_to_keep(n_in - 3'd2);
                    out_last = 1'b1;
                end
            end else if (wcnt >= W_FORWARD) begin
                out_valid = 1'b1;
                if (in_last & (avail <= 3'd4)) begin
                    out_keep = n_to_keep(avail);
                    out_last = 1'b1;
                end
            end
        end
    end

endmodule

`default_nettype wire
