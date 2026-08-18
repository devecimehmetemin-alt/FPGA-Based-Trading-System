module tb_book_update();

    localparam int MAXB = 262144;

    logic clk = 0;
    always #5 clk = ~clk;

    logic rst, flush;
    logic lvl_valid, lvl_side;
    logic [1:0] lvl_sym;
    logic [31:0] lvl_price;
    logic [31:0] lvl_qty;
    logic bbo_valid, bid_live, ask_live, degraded;
    logic [1:0] bbo_sym;
    logic [31:0] bid_price, bid_qty, ask_price, ask_qty;

    int e_sym [0:MAXB-1];
    int e_bl [0:MAXB-1];
    longint e_bp [0:MAXB-1];
    longint e_bq [0:MAXB-1];
    int e_al [0:MAXB-1];
    longint e_ap [0:MAXB-1];
    longint e_aq [0:MAXB-1];

    int n_exp = 0, got = 0, errors = 0, pushed = 0;

    book_update DUT(.*);

    task automatic push(input int sy, input int sd, input longint pr, input longint q);
        @(posedge clk); #1;
        lvl_valid = 1'b1;
        lvl_sym = 2'(sy);
        lvl_side = 1'(sd);
        lvl_price = 32'(pr);
        lvl_qty = 32'(q);
        @(posedge clk); #1;
        lvl_valid = 1'b0;
        pushed++;
    endtask

    task automatic cmp(input string name, input longint a, input longint b);
        if (a !== b) begin
            if (errors < 15)
                $error("bbo %0d %s: got %0d expected %0d", got, name, a, b);
            errors++;
        end
    endtask

    initial begin
        int fd, symv, sidev, blv, alv;
        longint prv, qtyv, bpv, bqv, apv, aqv;

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
        $display("loaded %0d expected bbo updates", n_exp);

        rst = 1; flush = 0; lvl_valid = 0; lvl_sym = 0; lvl_side = 0;
        lvl_price = 0; lvl_qty = 0;
        repeat (4) @(posedge clk);
        #1 rst = 0;
        repeat (2) @(posedge clk);

        // driven by price_level's own output, so a level that never reached the
        // ladder in the model never reaches it here either
        fd = $fopen("level_expect.txt", "r");
        if (fd == 0) begin
            $display("RESULT: FAIL");
            $fatal(1, "cannot open level_expect.txt");
        end
        while ($fscanf(fd, "%d %d %d %d\n", symv, sidev, prv, qtyv) == 4)
            push(symv, sidev, prv, qtyv);
        $fclose(fd);

        @(posedge clk); #1;
        lvl_valid = 0;
        repeat (20) @(posedge clk);

        $display("pushed=%0d checked=%0d/%0d degraded=%0b errors=%0d",
                 pushed, got, n_exp, degraded, errors);
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
                // a crossed book means the ladders disagree about the spread
                if (e_bl[got] && e_al[got] && bid_price >= ask_price) begin
                    if (errors < 15)
                        $error("bbo %0d crossed: bid %0d >= ask %0d",
                               got, bid_price, ask_price);
                    errors++;
                end
            end
            got++;
        end
    end

endmodule
