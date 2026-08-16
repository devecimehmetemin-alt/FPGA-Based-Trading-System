`default_nettype none

// Single clock, first word fall through. Sits between symbol_filter and
// order_store: nothing upstream can be held off, so a record arriving while
// order_store is stalled on an index collision or a replace would otherwise be
// dropped, and a dropped record leaves the book permanently wrong.
//
// The head is presented combinationally from distributed RAM, so a consumer can
// take it in the same cycle it appears rather than after a read strobe.

module sync_fifo #(
    parameter int DATA_W = 203,
    parameter int ADDR_W = 5
)(
    input wire logic clk,
    input wire logic rst,
    input wire logic wr_valid,
    input wire logic [DATA_W-1:0] wr_data,
    output logic wr_ready,
    input wire logic rd_ready,
    output logic rd_valid,
    output logic [DATA_W-1:0] rd_data,
    output logic [ADDR_W:0] level,
    output logic overflow
);

    localparam int DEPTH = 1 << ADDR_W;

    (* ram_style = "distributed" *)
    logic [DATA_W-1:0] mem [DEPTH];

    // one bit wider than the address so a full ring is distinguishable from an
    // empty one instead of aliasing onto it
    logic [ADDR_W:0] wptr, rptr;
    logic full, empty, push, pop;

    assign full = (wptr[ADDR_W] != rptr[ADDR_W])
               && (wptr[ADDR_W-1:0] == rptr[ADDR_W-1:0]);
    assign empty = (wptr == rptr);

    assign wr_ready = !full;
    assign rd_valid = !empty;
    assign rd_data = mem[rptr[ADDR_W-1:0]];
    assign level = wptr - rptr;

    assign push = wr_valid && !full;
    assign pop = rd_valid && rd_ready;

    always_ff @(posedge clk) begin
        if (push) mem[wptr[ADDR_W-1:0]] <= wr_data;
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            wptr <= '0;
            rptr <= '0;
            overflow <= 1'b0;
        end else begin
            if (push) wptr <= wptr + 1'b1;
            if (pop) rptr <= rptr + 1'b1;
            overflow <= wr_valid && full;
        end
    end

endmodule

`default_nettype wire
