module axis_cdc_fifo #(parameter int ADDR_W = 1000, parameter int PAYLOAD_W=10)(
    input wr_clk, wr_reset, wr_valid, wr_last, wr_fcs_ok, rd_clk, rd_reset, rd_ready,
    input [31:0] wr_data,
    output overflow, rd_fcs_ok, rd_last, rd_valid, wr_ready
    output [31:0] rd_data
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
    input unsync, clk, reset,
    output synced
);
    logic d1;

    always @(posedge clk ) begin
        if (reset) begin
            d1 <= 0;
            synced <= 0;
        end else begin
            d1 <= unsync;
            synced <= d1;
        end
    end

endmodule