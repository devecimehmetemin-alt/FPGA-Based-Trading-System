// The book half of book_top driven at real session depth.
//
// tb_book_top proves correctness but tops out around fifty live orders, because
// reaching real depth over Ethernet means simulating tens of millions of messages
// that the symbol filter throws away. This drives the same chain from the record
// stream that survives the filter, so the store reaches its full session
// occupancy and the latency can be measured against it.
//
// Correctness of the deltas is tb_book_top's job. What is checked here is what
// only shows up at depth: that the store never overflows a set, that occupancy
// tracks the model, and that latency does not degrade as the book fills.

module tb_book_chain();

    localparam int MAXR = 2000000;
    localparam int SHARES_W = 20;
    localparam int DELTA_W = SHARES_W + 1;
    localparam int QTY_W = 32;
    localparam int REC_W = 203;
    localparam int LVL_W = 2 + 1 + 32 + DELTA_W;
    localparam int REC_FIFO_AW = 5;
    localparam int LVL_FIFO_AW = 5;

    localparam logic [7:0] T_REPLACE = 8'h55;

    logic clk = 0;
    always #5 clk = ~clk;

    logic rst, flush;

    logic [REC_W-1:0] rec [0:MAXR-1];
    int n_rec, want_peak, want_final;

    // idle cycles between records. Four leaves both fifos empty, which is what the
    // wire looks like. Below two the level fifo overflows: order_store cannot be
    // held off by it, so the deltas are lost rather than delayed. Override with
    // -tclargs tb_book_chain gap:2 to see the queueing.
    int gap = 4;

    logic [REC_W-1:0] rec_wr, rec_rd;
    logic rec_v, rec_wr_ready, rec_q_valid, rec_q_ready, rec_fifo_ovf;
    logic [REC_FIFO_AW:0] rec_level;

    sync_fifo #(.DATA_W(REC_W), .ADDR_W(REC_FIFO_AW)) u_rec_fifo (
        .clk(clk),
        .rst(rst || flush),
        .wr_valid(rec_v),
        .wr_data(rec_wr),
        .wr_ready(rec_wr_ready),
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
    logic store_ovf, store_miss, store_dup;
    logic [17:0] store_occupancy;

    order_store #(.SHARES_W(SHARES_W)) u_store (
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

    logic [LVL_W-1:0] lvl_wr, lvl_rd;
    logic lvl_q_valid, lvl_q_ready, lvl_push, lvl_fifo_ovf;
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

    logic lvl_valid, lvl_side, lvl_ovf, lvl_miss;
    logic [1:0] lvl_sym;
    logic [31:0] lvl_price;
    logic [QTY_W-1:0] lvl_qty;
    logic [15:0] lvl_occupancy;

    price_level #(.DELTA_W(DELTA_W), .QTY_W(QTY_W)) u_levels (
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

    // the same registered boundary book_top has, so the ladder hop matches
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

    logic bbo_valid, bid_live, ask_live, degraded;
    logic [1:0] bbo_sym;
    logic [31:0] bid_price, bid_qty, ask_price, ask_qty;

    book_update #(.QTY_W(QTY_W)) u_book (
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

    // ---- measurement --------------------------------------------------------
    localparam int NBIN = 6;

    int cyc = 0, errors = 0;
    int sent = 0, n_bbo = 0, n_lvl = 0, n_repl = 0;
    int peak_occ = 0, peak_lvl_occ = 0, peak_rec_level = 0, peak_lvl_level = 0;
    int stall_cycles = 0, miss_count = 0;
    bit saw_rec_ovf = 0, saw_lvl_ovf = 0;
    localparam int L2 = 2;
    int l2_bad = 0, desync = 0;

    bit lv_hist [0:63];
    int lv_time [0:63];

    int q_rec [$], q_st_t [$];
    bit q_st_u [$];
    int q_lq [$], q_lvl [$];
    bit second_beat = 0;
    int held_t = 0;

    int b_n [0:NBIN-1];
    int b_min [0:NBIN-1];
    int b_max [0:NBIN-1];
    longint b_sum [0:NBIN-1];

    int tot_min = 1 << 30, tot_max = 0;
    longint tot_sum = 0;

    function automatic int bin_of(input int occ);
        int b;
        b = occ >> 13;
        return (b >= NBIN) ? NBIN - 1 : b;
    endfunction

    always @(negedge clk) begin
        if (!rst) begin
            cyc++;
            lv_hist[cyc % 64] = lvl_valid;

            if (store_occupancy > peak_occ) peak_occ = store_occupancy;
            if (lvl_occupancy > peak_lvl_occ) peak_lvl_occ = lvl_occupancy;
            if (rec_level > peak_rec_level) peak_rec_level = rec_level;
            if (lvl_level > peak_lvl_level) peak_lvl_level = lvl_level;
            if (rec_q_valid && !rec_q_ready) stall_cycles++;
            if (store_miss) miss_count++;

            if (store_ovf) begin
                if (errors < 10) $error("set overflow at occupancy %0d", store_occupancy);
                errors++;
            end
            if (lvl_ovf) begin
                if (errors < 10) $error("level set overflow at %0d levels", lvl_occupancy);
                errors++;
            end
            if (rec_fifo_ovf) saw_rec_ovf = 1'b1;
            if (lvl_fifo_ovf) saw_lvl_ovf = 1'b1;
            if (rec_fifo_ovf || lvl_fifo_ovf) begin
                if (errors < 10) $error("fifo overflow rec=%0b lvl=%0b",
                                        rec_fifo_ovf, lvl_fifo_ovf);
                errors++;
            end

            if (rec_v && rec_wr_ready) q_rec.push_back(cyc);

            if (rec_q_valid && rec_q_ready) begin
                if (q_rec.size() == 0) desync++;
                else begin
                    q_st_t.push_back(q_rec.pop_front());
                    // a replace is one record but two passes through the store,
                    // so its second output carries the same timestamp
                    q_st_u.push_back(rec_rd[202:195] == T_REPLACE);
                end
            end

            if (store_out_valid) begin
                int t;
                if (second_beat) begin
                    second_beat = 1'b0;
                    t = held_t;
                end else if (q_st_t.size() == 0) begin
                    desync++;
                    t = cyc;
                end else begin
                    t = q_st_t.pop_front();
                    if (q_st_u.pop_front()) begin
                        second_beat = 1'b1;
                        held_t = t;
                        n_repl++;
                    end
                end
                if (lvl_push) q_lq.push_back(t);
            end

            if (lvl_q_valid && lvl_q_ready) begin
                if (q_lq.size() == 0) desync++;
                else q_lvl.push_back(q_lq.pop_front());
            end

            if (lvl_valid) begin
                if (q_lvl.size() == 0) desync++;
                else begin
                    lv_time[cyc % 64] = q_lvl.pop_front();
                    n_lvl++;
                end
            end

            if (bbo_valid && cyc > L2) begin
                begin
                    if (!lv_hist[(cyc - L2) % 64]) begin
                        l2_bad++;
                    end else begin
                        int d, b;
                        d = cyc - lv_time[(cyc - L2) % 64];
                        b = bin_of(store_occupancy);
                        b_n[b]++;
                        b_sum[b] += d;
                        if (d < b_min[b]) b_min[b] = d;
                        if (d > b_max[b]) b_max[b] = d;
                        n_bbo++;
                        tot_sum += d;
                        if (d < tot_min) tot_min = d;
                        if (d > tot_max) tot_max = d;
                    end
                end
            end
        end
    end

    function automatic real ns(input real cycles);
        return cycles * 6.4;
    endfunction

    task automatic report();
        real avg;
        $display("");
        $display("record -> bbo latency by book depth, cycles and ns at 156.25 MHz");
        $display("  live orders        n        min   max   avg      avg ns");
        for (int b = 0; b < NBIN; b++) begin
            if (b_n[b] > 0) begin
                avg = real'(b_sum[b]) / real'(b_n[b]);
                $display("  %5dk-%2dk  %9d    %3d   %3d  %5.1f    %6.1f",
                         (b * 8), (b * 8 + 8), b_n[b], b_min[b], b_max[b], avg, ns(avg));
            end
        end
        avg = (n_bbo > 0) ? real'(tot_sum) / real'(n_bbo) : 0.0;
        $display("  overall    %9d    %3d   %3d  %5.1f    %6.1f",
                 n_bbo, tot_min, tot_max, avg, ns(avg));
        $display("");
        $display("  peak live orders   %0d (model said %0d)", peak_occ, want_peak);
        $display("  final live orders  %0d (model said %0d)", store_occupancy, want_final);
        $display("  peak live levels   %0d", peak_lvl_occ);
        $display("  replaces           %0d", n_repl);
        $display("  store stall cycles %0d of %0d (%0.2f%%)",
                 stall_cycles, cyc, 100.0 * real'(stall_cycles) / real'(cyc));
        $display("  peak fifo level    rec %0d/%0d, lvl %0d/%0d",
                 peak_rec_level, 1 << REC_FIFO_AW, peak_lvl_level, 1 << LVL_FIFO_AW);
        $display("  lookup misses      %0d", miss_count);
        $display("  ladder fixed at %0d, ladder misses %0d, desync %0d",
                 L2, l2_bad, desync);
        $display("  fifo overflow rec %0b lvl %0b", saw_rec_ovf, saw_lvl_ovf);
        $display("");
    endtask

    initial begin
        int fd, g;

        for (int b = 0; b < NBIN; b++) begin
            b_n[b] = 0; b_min[b] = 1 << 30; b_max[b] = 0; b_sum[b] = 0;
        end

        if ($value$plusargs("gap=%d", g)) gap = g;

        $readmemh("book_records.hex", rec);
        fd = $fopen("book_records.txt", "r");
        if (fd == 0) begin
            $display("RESULT: FAIL");
            $fatal(1, "cannot open book_records.txt, run scripts/extract_book_records.py");
        end
        if ($fscanf(fd, "%d %d %d", n_rec, want_peak, want_final) != 3) begin
            $display("RESULT: FAIL");
            $fatal(1, "book_records.txt is malformed");
        end
        $fclose(fd);
        $display("driving %0d records, gap %0d, model peak %0d final %0d",
                 n_rec, gap, want_peak, want_final);

        rst = 1; flush = 0; rec_v = 0; rec_wr = '0;
        repeat (4) @(posedge clk);
        #1 rst = 0;

        // the store walks every set clearing UltraRAM before it will accept
        @(negedge clk);
        while (!rec_q_ready) @(negedge clk);

        while (sent < n_rec) begin
            @(posedge clk); #1;
            rec_wr = rec[sent];
            rec_v = rec_wr_ready;
            @(negedge clk);
            if (rec_v && rec_wr_ready) begin
                sent++;
                if (gap > 0) begin
                    @(posedge clk); #1;
                    rec_v = 1'b0;
                    repeat (gap) @(posedge clk);
                    #1;
                end
            end
        end
        @(posedge clk); #1;
        rec_v = 1'b0;
        repeat (200) @(posedge clk);

        if (store_occupancy != want_final) begin
            $error("final occupancy %0d, model said %0d", store_occupancy, want_final);
            errors++;
        end
        if (peak_occ != want_peak) begin
            $error("peak occupancy %0d, model said %0d", peak_occ, want_peak);
            errors++;
        end
        if (q_rec.size() || q_st_t.size() || q_lq.size() || q_lvl.size()) begin
            $error("timestamps left in flight: %0d %0d %0d %0d, the measurement is unsound",
                   q_rec.size(), q_st_t.size(), q_lq.size(), q_lvl.size());
            errors++;
        end
        if (desync != 0 || l2_bad != 0) begin
            $error("desync %0d, ladder misses %0d, the measurement is unsound",
                   desync, l2_bad);
            errors++;
        end

        report();
        $display("records=%0d bbo=%0d levels=%0d errors=%0d", sent, n_bbo, n_lvl, errors);
        if (errors == 0 && sent == n_rec && n_bbo > 0) $display("RESULT: PASS");
        else $display("RESULT: FAIL");
        $finish;
    end

endmodule
