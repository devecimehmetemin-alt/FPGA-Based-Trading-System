module tb_book_top();

    localparam int MAXB = 1048576;
    localparam int MAXE = 262144;

    logic clk = 0;
    always #5 clk = ~clk;

    logic rst, resync, in_valid, in_last, in_fcs_ok;
    logic [63:0] in_data;
    logic [7:0] in_keep;
    logic bbo_valid, bid_live, ask_live;
    logic [1:0] bbo_sym;
    logic [31:0] bid_price, bid_qty, ask_price, ask_qty;
    logic book_stale, degraded, gap_pulse, dup_pulse, drop_pulse, pkt_bad, rec_err;
    logic [63:0] gap_from;
    logic [15:0] gap_count;
    logic rec_fifo_ovf, lvl_fifo_ovf, store_ovf, store_miss, store_dup;
    logic lvl_ovf, lvl_miss;
    logic [17:0] store_occupancy;
    logic [15:0] lvl_occupancy;

    logic [7:0] s_axi_awaddr, s_axi_araddr;
    logic s_axi_awvalid, s_axi_awready, s_axi_wvalid, s_axi_wready;
    logic [31:0] s_axi_wdata, s_axi_rdata;
    logic [3:0] s_axi_wstrb;
    logic [1:0] s_axi_bresp, s_axi_rresp;
    logic s_axi_bvalid, s_axi_bready, s_axi_arvalid, s_axi_arready;
    logic s_axi_rvalid, s_axi_rready;

    logic [79:0] ebeat [0:MAXB-1];

    int e_sym [0:MAXE-1];
    int e_bl [0:MAXE-1];
    longint e_bp [0:MAXE-1];
    longint e_bq [0:MAXE-1];
    int e_al [0:MAXE-1];
    longint e_ap [0:MAXE-1];
    longint e_aq [0:MAXE-1];

    int n_eth = 0, n_exp = 0, got = 0, errors = 0;

    book_top DUT(.*);

    task automatic axi_write(input logic [7:0] a, input logic [31:0] d);
        @(posedge clk); #1;
        s_axi_awaddr = a; s_axi_awvalid = 1'b1;
        s_axi_wdata = d; s_axi_wstrb = 4'hF; s_axi_wvalid = 1'b1;
        s_axi_bready = 1'b1;
        @(negedge clk);
        while (!(s_axi_awready && s_axi_wready)) @(negedge clk);
        @(posedge clk); #1;
        s_axi_awvalid = 1'b0; s_axi_wvalid = 1'b0;
        @(negedge clk);
        while (!s_axi_bvalid) @(negedge clk);
        @(posedge clk); #1;
        s_axi_bready = 1'b0;
    endtask

    task automatic axi_read(input logic [7:0] a, output logic [31:0] d);
        @(posedge clk); #1;
        s_axi_araddr = a; s_axi_arvalid = 1'b1; s_axi_rready = 1'b1;
        @(negedge clk);
        while (!s_axi_arready) @(negedge clk);
        @(posedge clk); #1;
        s_axi_arvalid = 1'b0;
        @(negedge clk);
        while (!s_axi_rvalid) @(negedge clk);
        d = s_axi_rdata;
        @(posedge clk); #1;
        s_axi_rready = 1'b0;
    endtask

    task automatic cmp(input string name, input longint a, input longint b);
        if (a !== b) begin
            if (errors < 15)
                $error("bbo %0d %s: got %0d expected %0d", got, name, a, b);
            errors++;
        end
    endtask

    initial begin
        int fd, symv, blv, alv;
        longint bpv, bqv, apv, aqv;
        logic [31:0] rv;

        $readmemh("eth_beats.hex", ebeat);
        while (n_eth < MAXB && !$isunknown(ebeat[n_eth])) n_eth++;

        fd = $fopen("bbo_expect.txt", "r");
        if (fd == 0) begin
            $display("RESULT: FAIL");
            $fatal(1, "cannot open bbo_expect.txt, run golden/book_model.py");
        end
        while ($fscanf(fd, "%d %d %d %d %d %d %d\n",
                       symv, blv, bpv, bqv, alv, apv, aqv) == 7) begin
            e_sym[n_exp] = symv;
            e_bl[n_exp] = blv; e_bp[n_exp] = bpv; e_bq[n_exp] = bqv;
            e_al[n_exp] = alv; e_ap[n_exp] = apv; e_aq[n_exp] = aqv;
            n_exp++;
        end
        $fclose(fd);
        $display("loaded %0d eth beats, %0d expected bbo updates", n_eth, n_exp);

        rst = 1; resync = 0; in_valid = 0; in_data = '0; in_keep = '0;
        in_last = 0; in_fcs_ok = 0;
        s_axi_awvalid = 0; s_axi_wvalid = 0; s_axi_bready = 0;
        s_axi_arvalid = 0; s_axi_rready = 0;
        s_axi_awaddr = 0; s_axi_araddr = 0; s_axi_wdata = 0; s_axi_wstrb = 0;
        repeat (4) @(posedge clk);
        #1 rst = 0;

        // order_store walks 8192 sets clearing UltraRAM before it can accept
        // anything, so the feed cannot start at reset
        repeat (9000) @(posedge clk);

        for (int i = 0; i < n_eth; i++) begin
            @(posedge clk); #1;
            {in_fcs_ok, in_last, in_keep, in_data} = ebeat[i][73:0];
            in_valid = 1;
        end
        @(posedge clk); #1;
        in_valid = 0; in_last = 0;
        repeat (100) @(posedge clk);

        if (book_stale) begin
            $error("book_stale set, a delta was lost somewhere in the chain");
            errors++;
        end

        // the register block must show software the same book the datapath ended
        // on, and the same counts the testbench watched go by
        axi_write(8'h04, 32'h1);
        axi_read(8'h00, rv);
        if (rv !== 32'h424F_4F4B) begin
            $error("axi id: got %08h expected 424F4F4B", rv);
            errors++;
        end
        axi_read(8'h10, rv);
        if (rv !== e_bp[n_exp-1]) begin
            $error("axi bid_price: got %0d expected %0d", rv, e_bp[n_exp-1]);
            errors++;
        end
        axi_read(8'h18, rv);
        if (rv !== e_ap[n_exp-1]) begin
            $error("axi ask_price: got %0d expected %0d", rv, e_ap[n_exp-1]);
            errors++;
        end
        axi_read(8'h20, rv);
        if (rv !== store_occupancy) begin
            $error("axi orders: got %0d expected %0d", rv, store_occupancy);
            errors++;
        end
        axi_read(8'h0C, rv);
        if (rv !== got) begin
            $error("axi bbo count: got %0d expected %0d", rv, got);
            errors++;
        end
        report_latency();
        $display("checked=%0d/%0d orders=%0d levels=%0d degraded=%0b errors=%0d",
                 got, n_exp, store_occupancy, lvl_occupancy, degraded, errors);
        if (errors == 0 && got == n_exp && got > 0) $display("RESULT: PASS");
        else $display("RESULT: FAIL");
        $finish;
    end

    always @(negedge clk) begin
        if (bbo_valid) begin
            if (got >= n_exp) begin
                if (errors < 15) $error("bbo %0d past the expected list", got);
                errors++;
            end else begin
                cmp("sym", bbo_sym, e_sym[got]);
                cmp("bid_live", bid_live, e_bl[got]);
                cmp("ask_live", ask_live, e_al[got]);
                if (e_bl[got]) begin
                    cmp("bid_price", bid_price, e_bp[got]);
                    cmp("bid_qty", bid_qty, e_bq[got]);
                end
                if (e_al[got]) begin
                    cmp("ask_price", ask_price, e_ap[got]);
                    cmp("ask_qty", ask_qty, e_aq[got]);
                end
                if (e_bl[got] && e_al[got] && bid_price >= ask_price) begin
                    if (errors < 15)
                        $error("bbo %0d crossed: bid %0d >= ask %0d",
                               got, bid_price, ask_price);
                    errors++;
                end
            end
            got++;
        end
        if (rec_fifo_ovf || lvl_fifo_ovf) begin
            if (errors < 15)
                $error("fifo overflow at bbo %0d: rec=%0b lvl=%0b",
                       got, rec_fifo_ovf, lvl_fifo_ovf);
            errors++;
        end
        if (store_ovf || lvl_ovf || store_dup) begin
            if (errors < 15)
                $error("store fault at bbo %0d: ovf=%0b lvl_ovf=%0b dup=%0b",
                       got, store_ovf, lvl_ovf, store_dup);
            errors++;
        end
        if (gap_pulse || dup_pulse || drop_pulse || pkt_bad || rec_err) begin
            if (errors < 15)
                $error("feed fault at bbo %0d: gap=%0b dup=%0b drop=%0b bad=%0b err=%0b",
                       got, gap_pulse, dup_pulse, drop_pulse, pkt_bad, rec_err);
            errors++;
        end
    end


    // ---- latency ------------------------------------------------------------
    // Endpoints are stated because the number is meaningless without them.
    //   t0  the last beat of an ITCH message has been taken in by mold_deframe,
    //       so the whole message is inside the fabric and can be acted on
    //   t1  the book update that message caused appears
    // What happens before t0 is the wire, not the design: a message cannot be
    // acted on before its last byte has arrived. That part is measured on its own
    // as the frame's last beat reaching the parser, which is exact because the
    // last ITCH message in a MoldUDP packet ends on the frame's last byte.
    //
    // Stages that never stall are checked to be fixed by looking for a strobe
    // exactly L cycles back on every event. Stages that do stall are one in one
    // out, so a queue of timestamps rides the pipeline with the data.
    int cyc = 0;
    bit ml_hist [0:63];
    bit lv_hist [0:63];
    int lv_time [0:63];

    int L1 = -1, L2 = -1;
    int l1_bad = 0, l2_bad = 0, desync = 0;

    int q_rec [$], q_store [$], q_lq [$], q_lvl [$];

    int n_tot = 0, tot_min = 1 << 30, tot_max = 0;
    longint tot_sum = 0;
    int n_lv = 0, lv_min = 1 << 30, lv_max = 0;
    longint lv_sum = 0;
    int n_fe = 0, fe_min = 1 << 30, fe_max = 0;
    longint fe_sum = 0;

    int frame_last_cyc = 0;
    bit fe_armed = 0;

    always @(negedge clk) begin
        if (!rst) begin
            cyc++;
            ml_hist[cyc % 64] = DUT.u_feed.msg_valid && DUT.u_feed.msg_last;
            lv_hist[cyc % 64] = DUT.lvl_valid;

            if (in_valid && in_last) begin
                frame_last_cyc = cyc;
                fe_armed = 1'b1;
            end else if (fe_armed && ml_hist[cyc % 64]) begin
                int d;
                d = cyc - frame_last_cyc;
                n_fe++;
                fe_sum += d;
                if (d < fe_min) fe_min = d;
                if (d > fe_max) fe_max = d;
                fe_armed = 1'b0;
            end

            if (DUT.rec_valid) begin
                if (L1 < 0)
                    for (int d = 0; d < 32 && d <= cyc && L1 < 0; d++)
                        if (ml_hist[(cyc - d) % 64]) L1 = d;
                if (L1 >= 0) begin
                    if (!ml_hist[(cyc - L1) % 64]) l1_bad++;
                    q_rec.push_back(cyc - L1);
                end
            end

            if (DUT.rec_q_valid && DUT.rec_q_ready) begin
                if (q_rec.size() == 0) desync++;
                else q_store.push_back(q_rec.pop_front());
            end

            if (DUT.store_out_valid) begin
                if (q_store.size() == 0) desync++;
                else begin
                    int t;
                    t = q_store.pop_front();
                    if (DUT.lvl_push) q_lq.push_back(t);
                end
            end

            if (DUT.lvl_q_valid && DUT.lvl_q_ready) begin
                if (q_lq.size() == 0) desync++;
                else q_lvl.push_back(q_lq.pop_front());
            end

            if (DUT.lvl_valid) begin
                if (q_lvl.size() == 0) desync++;
                else begin
                    int t, d;
                    t = q_lvl.pop_front();
                    lv_time[cyc % 64] = t;
                    d = cyc - t;
                    n_lv++;
                    lv_sum += d;
                    if (d < lv_min) lv_min = d;
                    if (d > lv_max) lv_max = d;
                end
            end

            if (bbo_valid) begin
                if (L2 < 0)
                    for (int d = 0; d < 32 && d <= cyc && L2 < 0; d++)
                        if (lv_hist[(cyc - d) % 64]) L2 = d;
                if (L2 >= 0) begin
                    if (!lv_hist[(cyc - L2) % 64]) begin
                        l2_bad++;
                    end else begin
                        int d;
                        d = cyc - lv_time[(cyc - L2) % 64];
                        n_tot++;
                        tot_sum += d;
                        if (d < tot_min) tot_min = d;
                        if (d > tot_max) tot_max = d;
                    end
                end
            end
        end
    end

    // 156.25 MHz is the 10G MAC clock the design is built for, 6.4 ns a cycle
    function automatic real ns(input real cycles);
        return cycles * 6.4;
    endfunction

    task automatic report_latency();
        real fe_avg, lv_avg, tot_avg;
        fe_avg = (n_fe > 0) ? real'(fe_sum) / real'(n_fe) : 0.0;
        lv_avg = (n_lv > 0) ? real'(lv_sum) / real'(n_lv) : 0.0;
        tot_avg = (n_tot > 0) ? real'(tot_sum) / real'(n_tot) : 0.0;
        $display("");
        $display("latency in cycles, ns at 156.25 MHz");
        $display("  frame last beat -> message in fabric  min %0d max %0d avg %0.1f  (%0.1f ns)",
                 fe_min, fe_max, fe_avg, ns(fe_avg));
        $display("  message in fabric -> level updated    min %0d max %0d avg %0.1f  (%0.1f ns)",
                 lv_min, lv_max, lv_avg, ns(lv_avg));
        $display("  message in fabric -> bbo updated      min %0d max %0d avg %0.1f  (%0.1f ns)",
                 tot_min, tot_max, tot_avg, ns(tot_avg));
        $display("  worst case in fabric %0d cycles (%0.1f ns), jitter %0d cycles",
                 tot_max, ns(real'(tot_max)), tot_max - tot_min);
        $display("  parse and filter fixed at %0d, ladder fixed at %0d", L1, L2);
        $display("  samples fe=%0d lvl=%0d bbo=%0d, fixed stage misses %0d/%0d, desync %0d",
                 n_fe, n_lv, n_tot, l1_bad, l2_bad, desync);
        $display("");
    endtask

endmodule
