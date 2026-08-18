`default_nettype none

// Withholds each frame until its start to start period has elapsed.

module frame_pacer (
    input wire logic clk,
    input wire logic rst,
    input wire logic req,
    input wire logic [31:0] period,
    output logic grant
);

    logic [31:0] cnt;

    assign grant = req & (cnt == 32'd0);

    always_ff @(posedge clk) begin
        if (rst) cnt <= 32'd0;
        else if (grant) cnt <= (period == 32'd0) ? 32'd0 : period - 32'd1;
        else if (cnt != 32'd0) cnt <= cnt - 32'd1;
    end

endmodule

`default_nettype wire
