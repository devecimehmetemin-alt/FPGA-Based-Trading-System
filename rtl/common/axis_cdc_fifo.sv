module axis_cdc_fifo #(
    parameter int ADDR_W = 9,
    parameter int DATA_W = 32
)(
    input logic wr_clk,
    input logic wr_reset,
    input logic wr_valid,
    input logic wr_last,
    input logic wr_fcs_ok,
    input logic [DATA_W-1:0] wr_data,
    output logic wr_ready,
    output logic overflow,

    input logic rd_clk,
    input logic rd_reset,
    input logic rd_ready,
    output logic rd_valid,
    output logic rd_last,
    output logic rd_fcs_ok,
    output logic [DATA_W-1:0] rd_data
);

    localparam int DEPTH = 1 << ADDR_W;

    logic [DATA_W+1:0] mem [DEPTH];

    logic [ADDR_W:0] b_wptr, b_rptr;
    logic [ADDR_W:0] g_wptr, g_wptr_sync, g_rptr, g_rptr_sync;
    logic full, empty;

    assign rd_valid = ~empty;

    assign {rd_last, rd_fcs_ok, rd_data} = mem[b_rptr[ADDR_W-1:0]];

    always_ff @(posedge wr_clk) begin
        if (wr_valid & wr_ready)
            mem[b_wptr[ADDR_W-1:0]] <= {wr_last, wr_fcs_ok, wr_data};
    end

    wptr_handler #(.ADDR_W(ADDR_W)) u_wptr_handler (
        .wr_clk(wr_clk),
        .wr_reset(wr_reset),
        .w_en(wr_valid),
        .g_rptr_sync(g_rptr_sync),
        .g_wptr(g_wptr),
        .b_wptr(b_wptr),
        .full(full),
        .overflow(overflow),
        .w_ready(wr_ready)
    );

    rptr_handler #(.ADDR_W(ADDR_W)) u_rptr_handler (
        .rd_clk(rd_clk),
        .rd_reset(rd_reset),
        .r_en(rd_valid & rd_ready),
        .g_wptr_sync(g_wptr_sync),
        .g_rptr(g_rptr),
        .b_rptr(b_rptr),
        .empty(empty)
    );

    synchroniser #(.W(ADDR_W+1)) u_sync_wr_to_rd (
        .clk(rd_clk),
        .reset(rd_reset),
        .in(g_wptr),
        .synced(g_wptr_sync)
    );

    synchroniser #(.W(ADDR_W+1)) u_sync_rd_to_wr (
        .clk(wr_clk),
        .reset(wr_reset),
        .in(g_rptr),
        .synced(g_rptr_sync)
    );

endmodule


module rptr_handler #(
    parameter int ADDR_W = 9
)(
    input logic rd_clk,
    input logic rd_reset,
    input logic r_en,
    input logic [ADDR_W:0] g_wptr_sync,
    output logic [ADDR_W:0] g_rptr,
    output logic [ADDR_W:0] b_rptr,
    output logic empty
);

    function automatic logic [ADDR_W:0] b2g(input logic [ADDR_W:0] b);
        return (b >> 1) ^ b;
    endfunction

    function automatic logic [ADDR_W:0] g2b(input logic [ADDR_W:0] g);
        logic [ADDR_W:0] b;
        b[ADDR_W] = g[ADDR_W];
        for (int i = ADDR_W-1; i >= 0; i--) b[i] = b[i+1] ^ g[i];
        return b;
    endfunction

    assign empty = (b_rptr == g2b(g_wptr_sync));

    always_ff @(posedge rd_clk) begin
        if (rd_reset) begin
            b_rptr <= '0;
            g_rptr <= '0;
        end else if (r_en) begin
            b_rptr <= b_rptr + 1'b1;
            g_rptr <= b2g(b_rptr + 1'b1);
        end
    end

endmodule


module wptr_handler #(
    parameter int ADDR_W = 9
)(
    input logic wr_clk,
    input logic wr_reset,
    input logic w_en,
    input logic [ADDR_W:0] g_rptr_sync,
    output logic [ADDR_W:0] g_wptr,
    output logic [ADDR_W:0] b_wptr,
    output logic full,
    output logic overflow,
    output logic w_ready
);

    localparam int DEPTH = 1 << ADDR_W;

    function automatic logic [ADDR_W:0] b2g(input logic [ADDR_W:0] b);
        return (b >> 1) ^ b;
    endfunction

    function automatic logic [ADDR_W:0] g2b(input logic [ADDR_W:0] g);
        logic [ADDR_W:0] b;
        b[ADDR_W] = g[ADDR_W];
        for (int i = ADDR_W-1; i >= 0; i--) b[i] = b[i+1] ^ g[i];
        return b;
    endfunction

    assign full = (b_wptr - g2b(g_rptr_sync)) == DEPTH;
    assign w_ready = ~full;

    always_ff @(posedge wr_clk) begin
        if (wr_reset) begin
            b_wptr <= '0;
            g_wptr <= '0;
            overflow <= 1'b0;
        end else begin
            if (w_en & ~w_ready)
                overflow <= 1'b1;

            if (w_en & w_ready) begin
                b_wptr <= b_wptr + 1'b1;
                g_wptr <= b2g(b_wptr + 1'b1);
            end
        end
    end

endmodule


module synchroniser #(
    parameter int W = 10
)(
    input logic clk,
    input logic reset,
    input logic [W-1:0] in,
    output logic [W-1:0] synced
);

    logic [W-1:0] d1;

    always_ff @(posedge clk) begin
        if (reset) begin
            d1 <= '0;
            synced <= '0;
        end else begin
            d1 <= in;
            synced <= d1;
        end
    end

endmodule
