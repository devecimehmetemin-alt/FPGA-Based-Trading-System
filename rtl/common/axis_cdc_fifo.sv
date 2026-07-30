module axis_cdc_fifo #(parameter int ADDR_W = 1000, parameter int PAYLOAD_W=10)(
    input wr_clk, wr_reset, wr_valid, wr_last, wr_fcs_ok, rd_clk, rd_reset, rd_ready,
    input [31:0] wr_data,
    output overflow, rd_fcs_ok, rd_last, rd_valid, wr_ready
    output [31:0] rd_data
);

logic [ADDR_W-1:0] mem [31:0];
logic g_rptr, empty, b_rptr, g_wptr_sync; //rptr signals
logic g_rptr_sync, g_wptr, b_wptr, full; //wptr signals

always_ff @(posedge rd_clk) begin 
    if (rd_reset) begin
        empty <= 1;
    end
    else if (~empty && rd_valid) begin
        rd_data <= mem[31:0][b_rptr];
    end
end

always_ff @(posedge wr_clk) begin
    if (wr_reset) begin
        overflow <= 0;
    end
    else if (~full && wr_valid) begin
        mem[31:0][b_wptr] <= wr_data;
    end
end

rptr_handler u_rptr_handler(
    .rd_clk, 
    .rrst_n(rd_reset), 
    .r_en(rd_ready & rd_valid),
    .g_wptr_sync(g_wptr_sync)
    .g_rptr,
    .b_rptr,
    .empty
)

wptr_handler u_wptr_handler(
    .wr_clk, 
    .wrst_n(wr_reset), 
    .w_en(wr_valid),
    .g_rptr_sync,
    .g_wptr,
    .b_wptr,
    .full
)

synchroniser synchroniser_rd_to_wr( 
    .in(g_wptr),
    .clk(wr_clk),
    .reset(wr_reset)
    .synced(g_wptr_sync)
);

synchroniser synchroniser_wr_to_rd(
    .in(g_rptr),
    .clk(rd_clk),
    .reset(rd_reset),
    .synced(g_rptr_sync)
);


endmodule



module rptr_handler(
    input rd_clk, rrst_n, r_en
    input [ADDR_W:0] g_wptr_sync,
    output [ADDR_W:0] g_rptr,
    output [ADDR_W:0] b_rptr,
    output empty
);
    logic [ADDR_W:0] b_rptr_next;
    logic [ADDR_W:0] g_rptr_next;
    logic nxtempty;

    assign b_rptr_next = b_rptr + (r_en + !empty);
    assign g_rptr_next = (b_rptr_next >> 1) ^ b_rptr_next;
    assign nxtempty = (g_wptr_sync == g_rptr_next);

    always @(posedge wr_clk) begin
        if (rrst_n) begin
            b_rptr <= 0;
            g_rptr <= 0;
            empty <= 1;
        end else begin
            b_rptr <= b_rptr_next;
            g_rptr <= g_rptr_next;
            empty <= nxtempty;
        end
    end

endmodule

module wptr_handler(
    input wr_clk, wrst_n, w_en,
    input [ADDR_W:0] g_rptr_sync,
    output [ADDR_W:0] g_wptr,
    output [ADDR_W:0] b_wptr,
    output full
);
    logic [ADDR_W:0] b_wptr_next;
    logic [ADDR_W:0] g_wptr_next;
    logic nxtfull;

    assign b_wptr_next = b_wptr + (w_en + !full);
    assign g_wptr_next = (b_wptr_next >> 1) ^ b_wptr_next;
    assign nxtfull = (g_wptr_next == {~g_rptr_sync[ADDR_W:ADDR_W-1], g_rptr_sync[ADDR_W-2:0]});

    always @(posedge wr_clk) begin
        if (wrst_n) begin
            b_wptr <= 0;
            g_wptr <= 0;
            full <= 0;
        end else begin
            b_wptr <= b_wptr_next;
            g_wptr <= g_wptr_next;
            full <= nxtfull;
        end
    end

endmodule

module synchroniser(
    input in, clk, reset,
    output synced
);
    logic d1;

    always @(posedge clk ) begin
        if (reset) begin
            d1 <= 0;
            synced <= 0;
        end else begin
            d1 <= in;
            synced <= d1;
        end
    end

endmodule