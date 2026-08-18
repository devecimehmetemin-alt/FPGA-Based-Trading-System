`default_nettype none

// Halves the DDR read width to the MAC datapath, low half of each wide word first.

module axis_narrow #(
    parameter int WIDE_W = 128
)(
    input wire logic clk,
    input wire logic rst,
    input wire logic in_valid,
    input wire logic [WIDE_W-1:0] in_data,
    output logic in_ready,
    output logic out_valid,
    output logic [WIDE_W/2-1:0] out_data,
    input wire logic out_ready
);

    localparam int HALF_W = WIDE_W / 2;

    logic phase;

    assign out_valid = in_valid;
    assign out_data = phase ? in_data[WIDE_W-1:HALF_W] : in_data[HALF_W-1:0];
    assign in_ready = out_ready & phase;

    always_ff @(posedge clk) begin
        if (rst) phase <= 1'b0;
        else if (out_valid & out_ready) phase <= ~phase;
    end

endmodule

`default_nettype wire
