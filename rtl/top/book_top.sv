`default_nettype none

// MAC beats in, top of book out.
//
//   feed_top -> rec fifo -> order_store -> lvl fifo -> price_level -> book_update
//
// Both fifos exist because the stage after them can stall and the stage before
// them cannot be held off: feed_top has no ready at all, and order_store cannot
// pause its output. A record dropped anywhere leaves the book permanently wrong
// rather than briefly wrong, so every overflow is latched into book_stale.

module book_top #(
    parameter logic [47:0] MCAST_MAC = 48'h01_00_5E_36_0C_6F,
    parameter logic [31:0] MCAST_IP = 32'hE9_36_0C_6F,
    parameter logic [15:0] FEED_PORT = 16'd26477,
    parameter int REC_FIFO_AW = 5,
    parameter int LVL_FIFO_AW = 5
)(
    input wire logic clk,
    input wire logic rst,
    input wire logic resync,
    input wire logic in_valid,
    input wire logic [63:0] in_data,
    input wire logic [7:0] in_keep,
    input wire logic in_last,
    input wire logic in_fcs_ok,

    input wire logic [7:0] s_axi_awaddr,
    input wire logic s_axi_awvalid,
    output logic s_axi_awready,
    input wire logic [31:0] s_axi_wdata,
    input wire logic [3:0] s_axi_wstrb,
    input wire logic s_axi_wvalid,
    output logic s_axi_wready,
    output logic [1:0] s_axi_bresp,
    output logic s_axi_bvalid,
    input wire logic s_axi_bready,
    input wire logic [7:0] s_axi_araddr,
    input wire logic s_axi_arvalid,
    output logic s_axi_arready,
    output logic [31:0] s_axi_rdata,
    output logic [1:0] s_axi_rresp,
    output logic s_axi_rvalid,
    input wire logic s_axi_rready,

    output logic bbo_valid,
    output logic [1:0] bbo_sym,
    output logic bid_live,
    output logic [31:0] bid_price,
    output logic [31:0] bid_qty,
    output logic ask_live,
    output logic [31:0] ask_price,
    output logic [31:0] ask_qty,

    output logic book_stale,
    output logic degraded,
    output logic gap_pulse,
    output logic [63:0] gap_from,
    output logic [15:0] gap_count,
    output logic dup_pulse,
    output logic drop_pulse,
    output logic pkt_bad,
    output logic rec_err,
    output logic rec_fifo_ovf,
    output logic lvl_fifo_ovf,
    output logic store_ovf,
    output logic store_miss,
    output logic store_dup,
    output logic lvl_ovf,
    output logic lvl_miss,
    output logic [17:0] store_occupancy,
    output logic [15:0] lvl_occupancy
);

    localparam int SHARES_W = 20;
    localparam int DELTA_W = SHARES_W + 1;
    localparam int QTY_W = 32;
    localparam int REC_W = 8 + 64 + 64 + 32 + 32 + 1 + 2;
    localparam int LVL_W = 2 + 1 + 32 + DELTA_W;

    // symbol_filter carries the stock string, not an index. With one watchlist
    // entry the index is constant; widening N_SYM means emitting which entry
    // matched and driving rec_sym from it.
    localparam logic [1:0] ONLY_SYM = 2'd0;

    logic rec_valid, rec_side;
    logic [7:0] rec_type;
    logic [63:0] rec_ref, rec_ref2;
    logic [31:0] rec_shares, rec_price;
    logic [15:0] rec_locate;
    logic [47:0] rec_time;
    logic [63:0] rec_seq, rec_stock;

    feed_top #(
        .MCAST_MAC(MCAST_MAC),
        .MCAST_IP(MCAST_IP),
        .FEED_PORT(FEED_PORT)
    ) u_feed (
        .clk(clk),
        .rst(rst),
        .in_valid(in_valid),
        .in_data(in_data),
        .in_keep(in_keep),
        .in_last(in_last),
        .in_fcs_ok(in_fcs_ok),
        .rec_valid(rec_valid),
        .rec_type(rec_type),
        .rec_locate(rec_locate),
        .rec_time(rec_time),
        .rec_seq(rec_seq),
        .rec_ref(rec_ref),
        .rec_ref2(rec_ref2),
        .rec_shares(rec_shares),
        .rec_price(rec_price),
        .rec_side(rec_side),
        .rec_stock(rec_stock),
        .rec_err(rec_err),
        .drop_pulse(drop_pulse),
        .pkt_bad(pkt_bad),
        .gap_pulse(gap_pulse),
        .gap_from(gap_from),
        .gap_count(gap_count),
        .dup_pulse(dup_pulse)
    );

    // a sequence gap means the book is missing deltas it will never see, so the
    // stores are cleared rather than left holding orders that no longer exist
    logic flush;
    assign flush = gap_pulse;

    logic [REC_W-1:0] rec_wr, rec_rd;
    logic rec_q_valid, rec_q_ready;
    logic [REC_FIFO_AW:0] rec_level;

    assign rec_wr = {rec_type, rec_ref, rec_ref2, rec_shares, rec_price, rec_side, ONLY_SYM};

    sync_fifo #(.DATA_W(REC_W), .ADDR_W(REC_FIFO_AW)) u_rec_fifo (
        .clk(clk),
        .rst(rst || flush),
        .wr_valid(rec_valid),
        .wr_data(rec_wr),
        .wr_ready(),
        .rd_ready(rec_q_ready),
        .rd_valid(rec_q_valid),
        .rd_data(rec_rd),
        .level(rec_level),
        .overflow(rec_fifo_ovf)
    );

    logic store_out_valid, store_out_hit, store_out_side, store_out_removed;
    logic [1:0] store_out_sym;
    logic [31:0] store_out_price;
    logic [SHARES_W-1:0] store_out_shares;
    logic signed [DELTA_W-1:0] store_out_delta;

    order_store #(
        .SHARES_W(SHARES_W)
    ) u_store (
        .clk(clk),
        .rst(rst),
        .flush(flush),
        .ready(rec_q_ready),
        .rec_valid(rec_q_valid),
        .rec_type(rec_rd[202:195]),
        .rec_ref(rec_rd[194:131]),
        .rec_ref2(rec_rd[130:67]),
        .rec_shares(rec_rd[66:35]),
        .rec_price(rec_rd[34:3]),
        .rec_side(rec_rd[2]),
        .rec_sym(rec_rd[1:0]),
        .out_valid(store_out_valid),
        .out_hit(store_out_hit),
        .out_sym(store_out_sym),
        .out_side(store_out_side),
        .out_price(store_out_price),
        .out_shares(store_out_shares),
        .out_delta(store_out_delta),
        .out_removed(store_out_removed),
        .ovf_pulse(store_ovf),
        .miss_pulse(store_miss),
        .dup_pulse(store_dup),
        .occupancy(store_occupancy)
    );

    // a miss or a refused insert yields a zero delta, which would move nothing
    logic [LVL_W-1:0] lvl_wr, lvl_rd;
    logic lvl_q_valid, lvl_q_ready, lvl_push;
    logic [LVL_FIFO_AW:0] lvl_level;

    assign lvl_push = store_out_valid && (store_out_delta != '0);
    assign lvl_wr = {store_out_sym, store_out_side, store_out_price, store_out_delta};

    sync_fifo #(.DATA_W(LVL_W), .ADDR_W(LVL_FIFO_AW)) u_lvl_fifo (
        .clk(clk),
        .rst(rst || flush),
        .wr_valid(lvl_push),
        .wr_data(lvl_wr),
        .wr_ready(),
        .rd_ready(lvl_q_ready),
        .rd_valid(lvl_q_valid),
        .rd_data(lvl_rd),
        .level(lvl_level),
        .overflow(lvl_fifo_ovf)
    );

    logic lvl_valid, lvl_side;
    logic [1:0] lvl_sym;
    logic [31:0] lvl_price;
    logic [QTY_W-1:0] lvl_qty;

    price_level #(
        .DELTA_W(DELTA_W),
        .QTY_W(QTY_W)
    ) u_levels (
        .clk(clk),
        .rst(rst),
        .flush(flush),
        .ready(lvl_q_ready),
        .upd_valid(lvl_q_valid),
        .upd_sym(lvl_rd[55:54]),
        .upd_side(lvl_rd[53]),
        .upd_price(lvl_rd[52:21]),
        .upd_delta(lvl_rd[20:0]),
        .lvl_valid(lvl_valid),
        .lvl_sym(lvl_sym),
        .lvl_side(lvl_side),
        .lvl_price(lvl_price),
        .lvl_qty(lvl_qty),
        .ovf_pulse(lvl_ovf),
        .miss_pulse(lvl_miss),
        .occupancy(lvl_occupancy)
    );

    // price_level's output feeds book_update's sorted insert, and that crossing is
    // the longest path in the integrated design even though neither module is
    // tight on its own. Registering it isolates the route and costs a cycle of
    // bbo latency, which nothing downstream consumes yet.
    logic q_valid, q_side;
    logic [1:0] q_sym;
    logic [31:0] q_price;
    logic [QTY_W-1:0] q_qty;

    always_ff @(posedge clk) begin
        if (rst || flush) q_valid <= 1'b0;
        else q_valid <= lvl_valid;
        q_sym <= lvl_sym;
        q_side <= lvl_side;
        q_price <= lvl_price;
        q_qty <= lvl_qty;
    end

    book_update #(
        .QTY_W(QTY_W)
    ) u_book (
        .clk(clk),
        .rst(rst),
        .flush(flush),
        .lvl_valid(q_valid),
        .lvl_sym(q_sym),
        .lvl_side(q_side),
        .lvl_price(q_price),
        .lvl_qty(q_qty),
        .bbo_valid(bbo_valid),
        .bbo_sym(bbo_sym),
        .bid_live(bid_live),
        .bid_price(bid_price),
        .bid_qty(bid_qty),
        .ask_live(ask_live),
        .ask_price(ask_price),
        .ask_qty(ask_qty),
        .degraded(degraded)
    );

    // every one of these means a delta was lost or never applied, and ITCH gives
    // no way to recover it from the live feed, so the flag is sticky until
    // software has resynchronised from a snapshot
    // software clears the flag through the register block once it has resynced
    // from a snapshot, or through the resync port for a bench driven reset
    logic axi_resync, clear_stale;
    assign clear_stale = resync || axi_resync;

    book_regs u_regs (
        .clk(clk),
        .rst(rst),
        .s_axi_awaddr(s_axi_awaddr),
        .s_axi_awvalid(s_axi_awvalid),
        .s_axi_awready(s_axi_awready),
        .s_axi_wdata(s_axi_wdata),
        .s_axi_wstrb(s_axi_wstrb),
        .s_axi_wvalid(s_axi_wvalid),
        .s_axi_wready(s_axi_wready),
        .s_axi_bresp(s_axi_bresp),
        .s_axi_bvalid(s_axi_bvalid),
        .s_axi_bready(s_axi_bready),
        .s_axi_araddr(s_axi_araddr),
        .s_axi_arvalid(s_axi_arvalid),
        .s_axi_arready(s_axi_arready),
        .s_axi_rdata(s_axi_rdata),
        .s_axi_rresp(s_axi_rresp),
        .s_axi_rvalid(s_axi_rvalid),
        .s_axi_rready(s_axi_rready),
        .bbo_valid(bbo_valid),
        .bid_live(bid_live),
        .bid_price(bid_price),
        .bid_qty(bid_qty),
        .ask_live(ask_live),
        .ask_price(ask_price),
        .ask_qty(ask_qty),
        .book_stale(book_stale),
        .degraded(degraded),
        .store_occupancy(store_occupancy),
        .lvl_occupancy(lvl_occupancy),
        .gap_from(gap_from),
        .gap_pulse(gap_pulse),
        .dup_pulse(dup_pulse),
        .drop_pulse(drop_pulse),
        .pkt_bad(pkt_bad),
        .rec_err(rec_err),
        .rec_fifo_ovf(rec_fifo_ovf),
        .lvl_fifo_ovf(lvl_fifo_ovf),
        .store_ovf(store_ovf),
        .store_miss(store_miss),
        .store_dup(store_dup),
        .lvl_ovf(lvl_ovf),
        .lvl_miss(lvl_miss),
        .resync(axi_resync)
    );

    always_ff @(posedge clk) begin
        if (rst || clear_stale) book_stale <= 1'b0;
        else if (gap_pulse || rec_fifo_ovf || lvl_fifo_ovf
                 || store_ovf || lvl_ovf) book_stale <= 1'b1;
    end

endmodule

`default_nettype wire
