module tb_order_store();

    localparam int MAXBY = 8388608;
    localparam int MAXM = 262144;
    localparam int NDIR = 7;

    logic clk = 0;
    always #5 clk = ~clk;

    logic rst, flush, ready;
    logic rec_valid, rec_side;
    logic [7:0] rec_type;
    logic [63:0] rec_ref, rec_ref2;
    logic [31:0] rec_shares, rec_price;
    logic [1:0] rec_sym;
    logic out_valid, out_hit, out_side, out_removed;
    logic [1:0] out_sym;
    logic [31:0] out_price;
    logic [19:0] out_shares;
    logic signed [20:0] out_delta;
    logic ovf_pulse, miss_pulse, dup_pulse;
    logic [17:0] occupancy;

    logic [7:0] gold [0:MAXBY-1];
    bit lmap [0:65535];

    int e_hit [0:MAXM-1];
    int e_sym [0:MAXM-1];
    int e_side [0:MAXM-1];
    longint e_price [0:MAXM-1];
    int e_shares [0:MAXM-1];
    int e_rem [0:MAXM-1];
    longint e_delta [0:MAXM-1];
    string d_name [NDIR];

    int n_gold = 0, n_exp = 0, got = 0, errors = 0, pushed = 0;
    bit vector_phase = 0;

    order_store DUT(.*);

    function automatic logic [63:0] fld(input int base, input int fo, input int wid);
        fld = '0;
        for (int i = 0; i < wid; i++) fld = {fld[55:0], gold[base + fo + i]};
    endfunction

    function automatic int symidx(input logic [63:0] s);
        symidx = (s == 64'h4141504C20202020) ? 0 : -1;
    endfunction

    task automatic push(input logic [7:0] t, input logic [63:0] r, input logic [63:0] r2,
                        input logic [31:0] sh, input logic [31:0] pr, input logic sd,
                        input logic [1:0] sy);
        @(posedge clk); #1;
        rec_valid = 1'b1; rec_type = t; rec_ref = r; rec_ref2 = r2;
        rec_shares = sh; rec_price = pr; rec_side = sd; rec_sym = sy;
        @(negedge clk);
        while (!ready) @(negedge clk);
        pushed++;
    endtask

    task automatic cmp(input string name, input longint a, input longint b);
        if (a !== b) begin
            if (errors < 15)
                $error("%s output %0d %s: got %0d expected %0d",
                       vector_phase ? "vector" : "directed", got, name, a, b);
            errors++;
        end
    endtask

    task automatic dexp(input int i, input string nm, input int h, input int sh,
                        input longint pr, input int rm, input longint d, input int sd);
        d_name[i] = nm;
        e_hit[i] = h; e_shares[i] = sh; e_price[i] = pr; e_rem[i] = rm;
        e_delta[i] = d; e_sym[i] = 0; e_side[i] = sd;
    endtask

    initial begin
        int fd, off, len, seq, hitv, symv, sidev, remv, shv, syi;
        longint prv, dltv;
        logic [63:0] a_ref, a_ref2, a_sh, a_pr;
        string kind, ekind;

        // a replace, and two messages on one ref back to back, are the cases the
        // captured vectors happen not to contain
        dexp(0, "add 1000", 1, 500, 1000000, 0,  500, 1);
        dexp(1, "exec 100", 1, 500, 1000000, 0, -100, 1);
        dexp(2, "exec 100", 1, 400, 1000000, 0, -100, 1);
        dexp(3, "repl del", 1, 300, 1000000, 1, -300, 1);
        dexp(4, "repl ins", 1, 250, 1010000, 0,  250, 1);
        dexp(5, "add 3000", 1, 700, 1020000, 0,  700, 1);
        dexp(6, "del 2000", 1, 250, 1010000, 1, -250, 1);
        n_exp = NDIR;

        rst = 1; flush = 0; rec_valid = 0; rec_type = 0; rec_ref = 0; rec_ref2 = 0;
        rec_shares = 0; rec_price = 0; rec_side = 0; rec_sym = 0;
        repeat (4) @(posedge clk);
        #1 rst = 0;
        @(negedge clk);
        while (!ready) @(negedge clk);
        if (occupancy !== 0) begin
            $error("occupancy=%0d after init, expected 0", occupancy);
            errors++;
        end

        push(8'h41, 64'd1000, '0, 32'd500, 32'd1000000, 1'b1, 2'd0);
        push(8'h45, 64'd1000, '0, 32'd100, '0, 1'b0, 2'd0);
        push(8'h45, 64'd1000, '0, 32'd100, '0, 1'b0, 2'd0);
        push(8'h55, 64'd1000, 64'd2000, 32'd250, 32'd1010000, 1'b0, 2'd0);
        push(8'h41, 64'd3000, '0, 32'd700, 32'd1020000, 1'b1, 2'd0);
        push(8'h44, 64'd2000, '0, '0, '0, 1'b0, 2'd0);
        @(posedge clk); #1;
        rec_valid = 0;
        repeat (30) @(posedge clk);

        if (got != NDIR) begin
            $error("directed phase gave %0d outputs, expected %0d", got, NDIR);
            errors++;
        end
        if (occupancy !== 1) begin
            $error("occupancy=%0d after directed phase, expected 1", occupancy);
            errors++;
        end

        @(posedge clk); #1;
        flush = 1;
        @(posedge clk); #1;
        flush = 0;
        @(negedge clk);
        while (!ready) @(negedge clk);
        if (occupancy !== 0) begin
            $error("occupancy=%0d after flush, expected 0", occupancy);
            errors++;
        end

        $readmemh("itch_expect.hex", gold);
        while (n_gold < MAXBY && !$isunknown(gold[n_gold])) n_gold++;

        fd = $fopen("order_expect.txt", "r");
        if (fd == 0) begin
            $display("RESULT: FAIL");
            $fatal(1, "cannot open order_expect.txt");
        end
        n_exp = 0;
        while ($fscanf(fd, "%d %s %d %d %d %d %d %d %d\n",
                       seq, ekind, hitv, symv, sidev, prv, shv, remv, dltv) == 9) begin
            e_hit[n_exp] = hitv; e_sym[n_exp] = symv; e_side[n_exp] = sidev;
            e_price[n_exp] = prv; e_shares[n_exp] = shv; e_rem[n_exp] = remv;
            e_delta[n_exp] = dltv;
            n_exp++;
        end
        $fclose(fd);
        got = 0;
        vector_phase = 1;
        $display("directed phase passed, %0d golden bytes, %0d vector records",
                 n_gold, n_exp);

        fd = $fopen("itch_expect.txt", "r");
        if (fd == 0) begin
            $display("RESULT: FAIL");
            $fatal(1, "cannot open itch_expect.txt");
        end
        while ($fscanf(fd, "%d %d %d %s", off, len, seq, kind) == 4) begin
            a_ref = fld(off, 11, 8);
            a_ref2 = '0;
            a_sh = '0;
            a_pr = '0;
            syi = 0;
            case (kind)
                "A", "F": begin
                    syi = symidx(fld(off, 24, 8));
                    a_sh = fld(off, 20, 4);
                    a_pr = fld(off, 32, 4);
                end
                "E", "C", "X": a_sh = fld(off, 19, 4);
                "U": begin
                    a_ref2 = fld(off, 19, 8);
                    a_sh = fld(off, 27, 4);
                    a_pr = fld(off, 31, 4);
                end
            endcase

            // A and F select on the stock string and teach that locate, every
            // later type is admitted on the locate alone
            case (kind)
                "A", "F": if (syi >= 0) begin
                    lmap[int'(fld(off, 1, 2))] = 1;
                    push(kind == "A" ? 8'h41 : 8'h46, a_ref, a_ref2, a_sh[31:0],
                         a_pr[31:0], gold[off + 19] == 8'h42, syi[1:0]);
                end
                "E": if (lmap[int'(fld(off, 1, 2))])
                    push(8'h45, a_ref, a_ref2, a_sh[31:0], a_pr[31:0], 1'b0, 2'b0);
                "C": if (lmap[int'(fld(off, 1, 2))])
                    push(8'h43, a_ref, a_ref2, a_sh[31:0], a_pr[31:0], 1'b0, 2'b0);
                "X": if (lmap[int'(fld(off, 1, 2))])
                    push(8'h58, a_ref, a_ref2, a_sh[31:0], a_pr[31:0], 1'b0, 2'b0);
                "D": if (lmap[int'(fld(off, 1, 2))])
                    push(8'h44, a_ref, a_ref2, a_sh[31:0], a_pr[31:0], 1'b0, 2'b0);
                "U": if (lmap[int'(fld(off, 1, 2))])
                    push(8'h55, a_ref, a_ref2, a_sh[31:0], a_pr[31:0], 1'b0, 2'b0);
            endcase
        end
        $fclose(fd);

        @(posedge clk); #1;
        rec_valid = 0;
        repeat (40) @(posedge clk);

        $display("pushed=%0d checked=%0d/%0d occupancy=%0d errors=%0d",
                 pushed, got, n_exp, occupancy, errors);
        if (errors == 0 && got == n_exp && got > 0) $display("RESULT: PASS");
        else $display("RESULT: FAIL");
        $finish;
    end

    always @(negedge clk) begin
        if (out_valid) begin
            if (got >= n_exp) begin
                if (errors < 15) $error("output %0d past the expected list", got);
                errors++;
            end else begin
                cmp("hit", out_hit, e_hit[got]);
                cmp("delta", longint'(out_delta), e_delta[got]);
                if (e_hit[got]) begin
                    cmp("sym", out_sym, e_sym[got]);
                    cmp("side", out_side, e_side[got]);
                    cmp("price", out_price, e_price[got]);
                    cmp("shares", out_shares, e_shares[got]);
                    cmp("removed", out_removed, e_rem[got]);
                end
            end
            got++;
        end
        if (ovf_pulse) begin
            if (errors < 15) $error("ovf_pulse at output %0d, ways exhausted", got);
            errors++;
        end
        if (dup_pulse) begin
            if (errors < 15) $error("dup_pulse at output %0d, ref inserted twice", got);
            errors++;
        end
    end

endmodule
