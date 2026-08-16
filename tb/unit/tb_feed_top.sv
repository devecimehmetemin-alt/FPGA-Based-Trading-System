module tb_feed_top();

    localparam int MAXB = 32768;
    localparam int MAXG = 131072;
    localparam int MAXM = 8192;

    logic clk = 0;
    always #5 clk = ~clk;

    logic rst, in_valid, in_last, in_fcs_ok;
    logic [63:0] in_data;
    logic [7:0] in_keep;
    logic rec_valid, rec_side, rec_err, drop_pulse, pkt_bad;
    logic [7:0] rec_type;
    logic [15:0] rec_locate;
    logic [47:0] rec_time;
    logic [63:0] rec_seq, rec_ref, rec_ref2, rec_stock;
    logic [31:0] rec_shares, rec_price;
    logic gap_pulse, dup_pulse;
    logic [63:0] gap_from;
    logic [15:0] gap_count;

    logic [79:0] ebeat [0:MAXB-1];
    logic [7:0] gold [0:MAXG-1];
    int eoff [0:MAXM-1];
    int eseq [0:MAXM-1];
    bit lmap [0:65535];

    int n_eth = 0, n_gold = 0, n_exp = 0;
    int got = 0, errors = 0;

    feed_top DUT(.*);

    function automatic logic [63:0] fld(input int base, input int off, input int w);
        fld = '0;
        for (int i = 0; i < w; i++) fld = {fld[55:0], gold[base + off + i]};
    endfunction

    function automatic logic wanted(input logic [63:0] s);
        wanted = (s == 64'h4141504C20202020);
    endfunction

    task automatic cmp(input string name, input logic [63:0] a, input logic [63:0] b);
        if (a !== b) begin
            if (errors < 10) $error("record %0d %s: got %0h expected %0h", got, name, a, b);
            errors++;
        end
    endtask

    initial begin
        int fd, o, l, s;
        string ty;

        $readmemh("eth_beats.hex", ebeat);
        $readmemh("itch_expect.hex", gold);
        while (n_eth < MAXB && !$isunknown(ebeat[n_eth])) n_eth++;
        while (n_gold < MAXG && !$isunknown(gold[n_gold])) n_gold++;

        fd = $fopen("itch_expect.txt", "r");
        if (fd == 0) begin
            $display("cannot open itch_expect.txt");
            $finish;
        end
        while ($fscanf(fd, "%d %d %d %s", o, l, s, ty) == 4) begin
            if (ty == "A" || ty == "F") begin
                if (wanted(fld(o, 24, 8))) begin
                    lmap[int'(fld(o, 1, 2))] = 1;
                    eoff[n_exp] = o;
                    eseq[n_exp] = s;
                    n_exp++;
                end
            end else if (ty == "E" || ty == "C" || ty == "X" || ty == "D" || ty == "U") begin
                if (lmap[int'(fld(o, 1, 2))]) begin
                    eoff[n_exp] = o;
                    eseq[n_exp] = s;
                    n_exp++;
                end
            end
        end
        $fclose(fd);
        $display("loaded %0d eth beats, %0d golden bytes, %0d records expected",
                 n_eth, n_gold, n_exp);

        rst = 1; in_valid = 0; in_data = '0; in_keep = '0; in_last = 0; in_fcs_ok = 0;
        repeat (4) @(posedge clk);
        #1 rst = 0;

        for (int i = 0; i < n_eth; i++) begin
            @(posedge clk); #1;
            {in_fcs_ok, in_last, in_keep, in_data} = ebeat[i][73:0];
            in_valid = 1;
        end
        @(posedge clk); #1;
        in_valid = 0; in_last = 0;
        repeat (20) @(posedge clk);

        $display("checked=%0d/%0d errors=%0d", got, n_exp, errors);
        if (errors == 0 && got == n_exp && got > 0) $display("RESULT: PASS");
        else $display("RESULT: FAIL");
        $finish;
    end

    always @(negedge clk) begin
        int b;
        if (rec_valid) begin
            if (got >= n_exp) begin
                if (errors < 10) $error("record %0d beyond the expected count", got);
                errors++;
            end else begin
                b = eoff[got];
                cmp("type", rec_type, gold[b]);
                cmp("locate", rec_locate, fld(b, 1, 2));
                cmp("time", rec_time, fld(b, 5, 6));
                cmp("seq", rec_seq, eseq[got]);
                cmp("ref", rec_ref, fld(b, 11, 8));
                case (gold[b])
                    8'h41, 8'h46: begin
                        cmp("side", rec_side, (gold[b+19] == 8'h42));
                        cmp("shares", rec_shares, fld(b, 20, 4));
                        cmp("stock", rec_stock, fld(b, 24, 8));
                        cmp("price", rec_price, fld(b, 32, 4));
                    end
                    8'h45, 8'h58: cmp("shares", rec_shares, fld(b, 19, 4));
                    8'h43: begin
                        cmp("shares", rec_shares, fld(b, 19, 4));
                        cmp("price", rec_price, fld(b, 32, 4));
                    end
                    8'h55: begin
                        cmp("ref2", rec_ref2, fld(b, 19, 8));
                        cmp("shares", rec_shares, fld(b, 27, 4));
                        cmp("price", rec_price, fld(b, 31, 4));
                    end
                endcase
            end
            got++;
        end
        if (rec_err) begin
            if (errors < 10) $error("rec_err asserted at record %0d", got);
            errors++;
        end
        if (drop_pulse) begin
            if (errors < 10) $error("drop_pulse asserted at record %0d", got);
            errors++;
        end
        if (pkt_bad) begin
            if (errors < 10) $error("pkt_bad asserted at record %0d", got);
            errors++;
        end
        if (gap_pulse) begin
            if (errors < 10)
                $error("gap_pulse at record %0d: %0d messages missing from %0d",
                       got, gap_count, gap_from);
            errors++;
        end
        if (dup_pulse) begin
            if (errors < 10) $error("dup_pulse asserted at record %0d", got);
            errors++;
        end
    end

endmodule
