`default_nettype none

module book_update #(
    parameter int N_SYM = 1,
    parameter int DEPTH = 8,
    parameter int QTY_W = 32
)(
    input wire logic clk,
    input wire logic rst,
    input wire logic flush,
    input wire logic lvl_valid,
    input wire logic [1:0] lvl_sym,
    input wire logic lvl_side,
    input wire logic [31:0] lvl_price,
    input wire logic [QTY_W-1:0] lvl_qty,
    output logic bbo_valid,
    output logic [1:0] bbo_sym,
    output logic bid_live,
    output logic [31:0] bid_price,
    output logic [QTY_W-1:0] bid_qty,
    output logic ask_live,
    output logic [31:0] ask_price,
    output logic [QTY_W-1:0] ask_qty,
    output logic degraded
);

    localparam int LADDERS = 2 * N_SYM;
    localparam int SEL_W = $clog2(LADDERS);
    localparam int CNT_W = $clog2(DEPTH + 1);

    // one ladder per side per symbol, best first, slots 0 to n-1 occupied. The
    // order makes insert and delete prefix shifts and puts the BBO at slot 0.
    logic [DEPTH-1:0][31:0] lad_px [LADDERS];
    logic [DEPTH-1:0][QTY_W-1:0] lad_qty [LADDERS];
    logic [CNT_W-1:0] lad_n [LADDERS];

    logic [SEL_W-1:0] sel, bid_sel, ask_sel;

    assign sel = SEL_W'({lvl_sym, lvl_side});
    assign bid_sel = SEL_W'({lvl_sym, 1'b1});
    assign ask_sel = SEL_W'({lvl_sym, 1'b0});

    logic [DEPTH-1:0][31:0] cur_px, nxt_px;
    logic [DEPTH-1:0][QTY_W-1:0] cur_qty, nxt_qty;
    logic [CNT_W-1:0] cur_n, nxt_n, pos;
    logic [DEPTH-1:0] used, match, better;
    logic gone, hit, ins_ok, wr, evict, top;

    always_comb begin
        cur_px = lad_px[sel];
        cur_qty = lad_qty[sel];
        cur_n = lad_n[sel];
        gone = (lvl_qty == '0);

        for (int i = 0; i < DEPTH; i++) begin
            used[i] = (i < int'(cur_n));
            match[i] = used[i] && (cur_px[i] == lvl_price);
            better[i] = !used[i] || (lvl_side ? (lvl_price > cur_px[i])
                                              : (lvl_price < cur_px[i]));
        end
        hit = |match;
        ins_ok = |better;

        // the ladder is sorted, so better is a suffix and its first bit is the
        // insertion point
        pos = '0;
        for (int i = DEPTH - 1; i >= 0; i--)
            if (hit ? match[i] : better[i]) pos = CNT_W'(i);

        wr = lvl_valid && (gone ? hit : (hit || ins_ok));
        evict = wr && !gone && !hit && (cur_n == CNT_W'(DEPTH));
        top = wr && (pos == '0);

        nxt_px = cur_px;
        nxt_qty = cur_qty;
        nxt_n = cur_n;
        if (gone && hit) begin
            for (int i = 0; i < DEPTH - 1; i++)
                if (i >= int'(pos)) begin
                    nxt_px[i] = cur_px[i+1];
                    nxt_qty[i] = cur_qty[i+1];
                end
            nxt_px[DEPTH-1] = '0;
            nxt_qty[DEPTH-1] = '0;
            nxt_n = cur_n - 1'b1;
        end else if (hit) begin
            nxt_qty[pos] = lvl_qty;
        end else if (ins_ok) begin
            for (int i = DEPTH - 1; i > 0; i--)
                if (i > int'(pos)) begin
                    nxt_px[i] = cur_px[i-1];
                    nxt_qty[i] = cur_qty[i-1];
                end
            nxt_px[pos] = lvl_price;
            nxt_qty[pos] = lvl_qty;
            if (cur_n != CNT_W'(DEPTH)) nxt_n = cur_n + 1'b1;
        end
    end

    // a price worse than every slot of a full ladder is outside the top DEPTH
    // and is simply dropped. An insert that pushes an occupied last slot out is
    // a level lost, and only that can leave the BBO stale later.
    always_ff @(posedge clk) begin
        if (rst || flush) begin
            for (int j = 0; j < LADDERS; j++) lad_n[j] <= '0;
            degraded <= 1'b0;
        end else if (wr) begin
            lad_px[sel] <= nxt_px;
            lad_qty[sel] <= nxt_qty;
            lad_n[sel] <= nxt_n;
            if (evict) degraded <= 1'b1;
        end
    end

    logic [31:0] top_bid_px, top_ask_px;
    logic [QTY_W-1:0] top_bid_qty, top_ask_qty;
    logic top_bid_live, top_ask_live;

    always_comb begin
        top_bid_px = lvl_side ? nxt_px[0] : lad_px[bid_sel][0];
        top_bid_qty = lvl_side ? nxt_qty[0] : lad_qty[bid_sel][0];
        top_bid_live = (lvl_side ? nxt_n : lad_n[bid_sel]) != '0;
        top_ask_px = lvl_side ? lad_px[ask_sel][0] : nxt_px[0];
        top_ask_qty = lvl_side ? lad_qty[ask_sel][0] : nxt_qty[0];
        top_ask_live = (lvl_side ? lad_n[ask_sel] : nxt_n) != '0;
    end

    always_ff @(posedge clk) begin
        if (rst || flush) begin
            bbo_valid <= 1'b0;
            bid_live <= 1'b0;
            ask_live <= 1'b0;
        end else begin
            bbo_valid <= top;
            if (top) begin
                bbo_sym <= lvl_sym;
                bid_live <= top_bid_live;
                bid_price <= top_bid_px;
                bid_qty <= top_bid_qty;
                ask_live <= top_ask_live;
                ask_price <= top_ask_px;
                ask_qty <= top_ask_qty;
            end
        end
    end

endmodule

`default_nettype wire
