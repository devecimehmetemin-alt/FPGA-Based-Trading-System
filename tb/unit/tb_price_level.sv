module tb_price_level();

    localparam int MAXL = 262144;

    logic clk = 0;
    always #5 clk = ~clk;

    logic rst, flush, ready;
    logic upd_valid, upd_side;
    logic [1:0] upd_sym;
    logic [31:0] upd_price;
    logic signed [20:0] upd_delta;
    logic lvl_valid, lvl_side;
    logic [1:0] lvl_sym;
    logic [31:0] lvl_price;
    logic [31:0] lvl_qty;
    logic ovf_pulse, miss_pulse;
    logic [13:0] occupancy;

    int e_sym [0:MAXL-1];
    int e_side [0:MAXL-1];
    longint e_price [0:MAXL-1];
    longint e_qty [0:MAXL-1];

    int n_exp = 0, got = 0, errors = 0, pushed = 0;

    price_level DUT(.*);

    task automatic push(input int sy, input int sd, input longint pr, input longint d);
        @(posedge clk); #1;
        upd_valid = 1'b1;
        upd_sym = 2'(sy);
        upd_side = 1'(sd);
        upd_price = 32'(pr);
        upd_delta = 21'(d);
        @(negedge clk);
        while (!ready) @(negedge clk);
        pushed++;
    endtask

    task automatic cmp(input string name, input longint a, input longint b);
        if (a !== b) begin
            if (errors < 15)
                $error("level %0d %s: got %0d expected %0d", got, name, a, b);
            errors++;
        end
    endtask

    initial begin
        int fd, seq, hitv, symv, sidev, remv, shv;
        longint prv, dltv, qtyv;
        string ekind;

        fd = $fopen("level_expect.txt", "r");
        if (fd == 0) begin
            $display("RESULT: FAIL");
            $fatal(1, "cannot open level_expect.txt, run golden/book_model.py");
        end
        while ($fscanf(fd, "%d %d %d %d\n", symv, sidev, prv, qtyv) == 4) begin
            e_sym[n_exp] = symv; e_side[n_exp] = sidev;
            e_price[n_exp] = prv; e_qty[n_exp] = qtyv;
            n_exp++;
        end
        $fclose(fd);
        $display("loaded %0d expected level updates", n_exp);

        rst = 1; flush = 0; upd_valid = 0; upd_sym = 0; upd_side = 0;
        upd_price = 0; upd_delta = 0;
        repeat (4) @(posedge clk);
        #1 rst = 0;
        @(negedge clk);
        while (!ready) @(negedge clk);
        if (occupancy !== 0) begin
            $error("occupancy=%0d after init, expected 0", occupancy);
            errors++;
        end

        // stimulus is order_store's own output, so each stage is driven by the
        // stage before it rather than by a separate parse of the feed
        fd = $fopen("order_expect.txt", "r");
        if (fd == 0) begin
            $display("RESULT: FAIL");
            $fatal(1, "cannot open order_expect.txt");
        end
        while ($fscanf(fd, "%d %s %d %d %d %d %d %d %d\n",
                       seq, ekind, hitv, symv, sidev, prv, shv, remv, dltv) == 9) begin
            if (dltv != 0) push(symv, sidev, prv, dltv);
        end
        $fclose(fd);

        @(posedge clk); #1;
        upd_valid = 0;
        repeat (40) @(posedge clk);

        $display("pushed=%0d checked=%0d/%0d occupancy=%0d errors=%0d",
                 pushed, got, n_exp, occupancy, errors);
        if (errors == 0 && got == n_exp && got > 0) $display("RESULT: PASS");
        else $display("RESULT: FAIL");
        $finish;
    end

    always @(negedge clk) begin
        if (lvl_valid) begin
            if (got >= n_exp) begin
                if (errors < 15) $error("level %0d past the expected list", got);
                errors++;
            end else begin
                cmp("sym", lvl_sym, e_sym[got]);
                cmp("side", lvl_side, e_side[got]);
                cmp("price", lvl_price, e_price[got]);
                cmp("qty", lvl_qty, e_qty[got]);
            end
            got++;
        end
        if (ovf_pulse) begin
            if (errors < 15) $error("ovf_pulse at level %0d, ways exhausted", got);
            errors++;
        end
    end

endmodule
