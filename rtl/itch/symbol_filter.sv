`default_nettype none

module symbol_filter #(
    parameter int N_SYM = 4,
    // 8 byte ASCII, space padded, first character in the high byte
    parameter logic [64*N_SYM-1:0] SYMBOLS = {
        64'h52494F2020202020, // RIO
        64'h474E572020202020, // GNW
        64'h5341502020202020, // SAP
        64'h5A565A5A54202020  // ZVZZT
    }
)(
    input wire logic clk,
    input wire logic rst,
    input wire logic rec_valid,
    input wire logic [7:0] rec_type,
    input wire logic [15:0] rec_locate,
    input wire logic [47:0] rec_time,
    input wire logic [63:0] rec_seq,
    input wire logic [63:0] rec_ref,
    input wire logic [63:0] rec_ref2,
    input wire logic [31:0] rec_shares,
    input wire logic [31:0] rec_price,
    input wire logic rec_side,
    input wire logic [63:0] rec_stock,
    output logic out_valid,
    output logic [7:0] out_type,
    output logic [15:0] out_locate,
    output logic [47:0] out_time,
    output logic [63:0] out_seq,
    output logic [63:0] out_ref,
    output logic [63:0] out_ref2,
    output logic [31:0] out_shares,
    output logic [31:0] out_price,
    output logic out_side,
    output logic [63:0] out_stock
);

    // Only A and F carry a stock symbol

    logic match, admit;

    always_comb begin
        match = 1'b0;
        for (int i = 0; i < N_SYM; i++)
            if (rec_stock == SYMBOLS[64*i +: 64]) match = 1'b1;
    end

    assign admit = match | (rec_type != 8'h41 && rec_type != 8'h46);

    always_ff @(posedge clk) begin
        if (rst) out_valid <= 1'b0;
        else out_valid <= rec_valid & admit;
        out_type <= rec_type;
        out_locate <= rec_locate;
        out_time <= rec_time;
        out_seq <= rec_seq;
        out_ref <= rec_ref;
        out_ref2 <= rec_ref2;
        out_shares <= rec_shares;
        out_price <= rec_price;
        out_side <= rec_side;
        out_stock <= rec_stock;
    end

endmodule

`default_nettype wire
