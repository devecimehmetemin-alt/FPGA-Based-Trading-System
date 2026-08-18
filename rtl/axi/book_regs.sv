`default_nettype none

// AXI4-Lite view of the book, for software on the PS to read over SSH.
//
// The book moves millions of times a second and a terminal manages tens, so a
// reader always sees a sample. Writing SNAP latches the whole set in one cycle
// into shadow registers, which is the only way the four BBO fields come from the
// same instant; reading them one at a time from the live signals would now and
// then render a crossed book that never existed.
//
// Single clock on purpose. Drive the PS AXI clock from the same PL clock as the
// datapath and there is no crossing here to get wrong.
//
//   0x00 ID          R   "BOOK"
//   0x04 CTRL        W   [0] snapshot  [1] resync, clears stale and counters
//   0x08 STATUS      R   [0] stale [1] degraded [2] bid_live [3] ask_live
//   0x0C BBO_COUNT   R   free running, tells a reader the book moved
//   0x10 BID_PRICE   R
//   0x14 BID_QTY     R
//   0x18 ASK_PRICE   R
//   0x1C ASK_QTY     R
//   0x20 ORDERS      R   resting orders held
//   0x24 LEVELS      R   distinct price levels held
//   0x28 GAP_FROM_LO R
//   0x2C GAP_FROM_HI R
//   0x30..0x5C       R   event counters, saturating

module book_regs #(
    parameter int ADDR_W = 8
)(
    input wire logic clk,
    input wire logic rst,

    input wire logic [ADDR_W-1:0] s_axi_awaddr,
    input wire logic s_axi_awvalid,
    output logic s_axi_awready,
    input wire logic [31:0] s_axi_wdata,
    input wire logic [3:0] s_axi_wstrb,
    input wire logic s_axi_wvalid,
    output logic s_axi_wready,
    output logic [1:0] s_axi_bresp,
    output logic s_axi_bvalid,
    input wire logic s_axi_bready,
    input wire logic [ADDR_W-1:0] s_axi_araddr,
    input wire logic s_axi_arvalid,
    output logic s_axi_arready,
    output logic [31:0] s_axi_rdata,
    output logic [1:0] s_axi_rresp,
    output logic s_axi_rvalid,
    input wire logic s_axi_rready,

    input wire logic bbo_valid,
    input wire logic bid_live,
    input wire logic [31:0] bid_price,
    input wire logic [31:0] bid_qty,
    input wire logic ask_live,
    input wire logic [31:0] ask_price,
    input wire logic [31:0] ask_qty,
    input wire logic book_stale,
    input wire logic degraded,
    input wire logic [17:0] store_occupancy,
    input wire logic [15:0] lvl_occupancy,
    input wire logic [63:0] gap_from,

    input wire logic gap_pulse,
    input wire logic dup_pulse,
    input wire logic drop_pulse,
    input wire logic pkt_bad,
    input wire logic rec_err,
    input wire logic rec_fifo_ovf,
    input wire logic lvl_fifo_ovf,
    input wire logic store_ovf,
    input wire logic store_miss,
    input wire logic store_dup,
    input wire logic lvl_ovf,
    input wire logic lvl_miss,

    output logic resync
);

    localparam int NCNT = 12;
    localparam logic [31:0] MAGIC = 32'h424F_4F4B;

    logic [NCNT-1:0] ev;
    logic [31:0] cnt [NCNT];
    logic [31:0] bbo_count;

    assign ev = {lvl_miss, lvl_ovf, store_dup, store_miss, store_ovf,
                 lvl_fifo_ovf, rec_fifo_ovf, rec_err, pkt_bad, drop_pulse,
                 dup_pulse, gap_pulse};

    logic snap;

    // shadow copy, so the four BBO fields a reader sees share one instant
    logic s_stale, s_degraded, s_bid_live, s_ask_live;
    logic [31:0] s_bid_price, s_bid_qty, s_ask_price, s_ask_qty;
    logic [31:0] s_orders, s_levels, s_bbo_count;
    logic [63:0] s_gap_from;
    logic [31:0] s_cnt [NCNT];

    always_ff @(posedge clk) begin
        if (rst) begin
            bbo_count <= '0;
            for (int i = 0; i < NCNT; i++) cnt[i] <= '0;
        end else if (resync) begin
            bbo_count <= '0;
            for (int i = 0; i < NCNT; i++) cnt[i] <= '0;
        end else begin
            if (bbo_valid && bbo_count != '1) bbo_count <= bbo_count + 1'b1;
            for (int i = 0; i < NCNT; i++)
                if (ev[i] && cnt[i] != '1) cnt[i] <= cnt[i] + 1'b1;
        end
    end

    always_ff @(posedge clk) begin
        if (snap) begin
            s_stale <= book_stale;
            s_degraded <= degraded;
            s_bid_live <= bid_live;
            s_ask_live <= ask_live;
            s_bid_price <= bid_price;
            s_bid_qty <= bid_qty;
            s_ask_price <= ask_price;
            s_ask_qty <= ask_qty;
            s_orders <= 32'(store_occupancy);
            s_levels <= 32'(lvl_occupancy);
            s_bbo_count <= bbo_count;
            s_gap_from <= gap_from;
            for (int i = 0; i < NCNT; i++) s_cnt[i] <= cnt[i];
        end
    end

    // one outstanding transaction each way, no bursts, no protection checks
    logic wr_go, rd_go;
    logic [ADDR_W-1:0] wr_addr, rd_addr;

    assign wr_go = s_axi_awvalid && s_axi_wvalid && !s_axi_bvalid;
    assign s_axi_awready = wr_go;
    assign s_axi_wready = wr_go;
    assign wr_addr = s_axi_awaddr;

    assign rd_go = s_axi_arvalid && !s_axi_rvalid;
    assign s_axi_arready = rd_go;
    assign rd_addr = s_axi_araddr;

    assign s_axi_bresp = 2'b00;
    assign s_axi_rresp = 2'b00;

    always_ff @(posedge clk) begin
        if (rst) begin
            s_axi_bvalid <= 1'b0;
            snap <= 1'b0;
            resync <= 1'b0;
        end else begin
            snap <= 1'b0;
            resync <= 1'b0;
            if (wr_go) begin
                s_axi_bvalid <= 1'b1;
                if (wr_addr[ADDR_W-1:2] == 6'h1 && s_axi_wstrb[0]) begin
                    snap <= s_axi_wdata[0];
                    resync <= s_axi_wdata[1];
                end
            end else if (s_axi_bvalid && s_axi_bready) begin
                s_axi_bvalid <= 1'b0;
            end
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            s_axi_rvalid <= 1'b0;
            s_axi_rdata <= '0;
        end else if (rd_go) begin
            s_axi_rvalid <= 1'b1;
            case (rd_addr[ADDR_W-1:2])
                6'h0: s_axi_rdata <= MAGIC;
                6'h2: s_axi_rdata <= {28'd0, s_ask_live, s_bid_live,
                                      s_degraded, s_stale};
                6'h3: s_axi_rdata <= s_bbo_count;
                6'h4: s_axi_rdata <= s_bid_price;
                6'h5: s_axi_rdata <= s_bid_qty;
                6'h6: s_axi_rdata <= s_ask_price;
                6'h7: s_axi_rdata <= s_ask_qty;
                6'h8: s_axi_rdata <= s_orders;
                6'h9: s_axi_rdata <= s_levels;
                6'hA: s_axi_rdata <= s_gap_from[31:0];
                6'hB: s_axi_rdata <= s_gap_from[63:32];
                default: begin
                    if (rd_addr[ADDR_W-1:2] >= 6'hC
                        && rd_addr[ADDR_W-1:2] < 6'(6'hC + NCNT))
                        s_axi_rdata <= s_cnt[rd_addr[ADDR_W-1:2] - 6'hC];
                    else
                        s_axi_rdata <= '0;
                end
            endcase
        end else if (s_axi_rvalid && s_axi_rready) begin
            s_axi_rvalid <= 1'b0;
        end
    end

endmodule

`default_nettype wire
