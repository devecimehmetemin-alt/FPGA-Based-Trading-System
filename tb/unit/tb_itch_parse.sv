module tb_itch_parse();

    localparam int MAXG = 131072;
    localparam int MAXM = 8192;
    localparam int MAXBEAT = 15;

    logic clk = 0;
    always #5 clk = ~clk;

    logic rst, msg_valid, msg_start, msg_last;
    logic [127:0] msg_data;
    logic [15:0] msg_keep;
    logic [15:0] msg_len;
    logic [63:0] msg_seq;
    logic rec_valid, rec_side, rec_err;
    logic [7:0] rec_type;
    logic [15:0] rec_locate;
    logic [47:0] rec_time;
    logic [63:0] rec_seq, rec_ref, rec_ref2, rec_stock;
    logic [31:0] rec_shares, rec_price;

    logic [7:0] gold [0:MAXG-1];
    int moff [0:MAXM-1];
    int mlen [0:MAXM-1];
    int mseq [0:MAXM-1];
    int widx [0:MAXM-1];

    int n_gold = 0, n_msg = 0, n_want = 0;
    int sent = 0, got = 0, errors = 0;

    itch_parse DUT(.*);

    function automatic logic [63:0] fld(input int base, input int off, input int w);
        fld = '0;
        for (int i = 0; i < w; i++) fld = {fld[55:0], gold[base + off + i]};
    endfunction

    task automatic cmp(input string name, input logic [63:0] a, input logic [63:0] b, input int m);
        if (a !== b) begin
            if (errors < 10) $error("msg %0d %s: got %0h expected %0h", m, name, a, b);
            errors++;
        end
    endtask

    initial begin
        int fd, o, l, s, pos, n, bsz;
        string ty;

        $readmemh("itch_expect.hex", gold);
        while (n_gold < MAXG && !$isunknown(gold[n_gold])) n_gold++;

        fd = $fopen("itch_expect.txt", "r");
        if (fd == 0) begin
            $display("cannot open itch_expect.txt");
            $finish;
        end
        while ($fscanf(fd, "%d %d %d %s", o, l, s, ty) == 4) begin
            moff[n_msg] = o;
            mlen[n_msg] = l;
            mseq[n_msg] = s;
            if (ty == "A" || ty == "F" || ty == "E" || ty == "C" ||
                ty == "X" || ty == "D" || ty == "U") begin
                widx[n_want] = n_msg;
                n_want++;
            end
            n_msg++;
        end
        $fclose(fd);
        $display("loaded %0d golden bytes, %0d messages, %0d of interest",
                 n_gold, n_msg, n_want);

        rst = 1; msg_valid = 0; msg_data = '0; msg_keep = '0;
        msg_start = 0; msg_last = 0; msg_len = '0; msg_seq = '0;
        repeat (4) @(posedge clk);
        #1 rst = 0;

        for (int m = 0; m < n_msg; m++) begin
            pos = 0;
            while (pos < mlen[m]) begin
                bsz = $urandom_range(1, MAXBEAT);
                n = (mlen[m] - pos > bsz) ? bsz : mlen[m] - pos;
                @(posedge clk); #1;
                msg_data = '0;
                for (int i = 0; i < n; i++)
                    msg_data[8*i +: 8] = gold[moff[m] + pos + i];
                msg_keep = (16'd1 << n) - 16'd1;
                msg_start = (pos == 0);
                msg_last = (pos + n == mlen[m]);
                msg_len = 16'(mlen[m]);
                msg_seq = 64'(mseq[m]);
                msg_valid = 1;
                pos = pos + n;
            end
            sent++;
        end
        @(posedge clk); #1;
        msg_valid = 0; msg_start = 0; msg_last = 0;
        repeat (10) @(posedge clk);

        $display("sent=%0d checked=%0d/%0d errors=%0d", sent, got, n_want, errors);
        if (errors == 0 && got == n_want && got > 0) $display("RESULT: PASS");
        else $display("RESULT: FAIL");
        $finish;
    end

    always @(negedge clk) begin
        int b;
        if (rec_valid) begin
            if (got >= n_want) begin
                if (errors < 10) $error("record %0d beyond the expected count", got);
                errors++;
            end else begin
                b = moff[widx[got]];
                cmp("type", rec_type, gold[b], got);
                cmp("locate", rec_locate, fld(b, 1, 2), got);
                cmp("time", rec_time, fld(b, 5, 6), got);
                cmp("seq", rec_seq, mseq[widx[got]], got);
                cmp("ref", rec_ref, fld(b, 11, 8), got);
                case (gold[b])
                    8'h41, 8'h46: begin
                        cmp("side", rec_side, (gold[b+19] == 8'h42), got);
                        cmp("shares", rec_shares, fld(b, 20, 4), got);
                        cmp("stock", rec_stock, fld(b, 24, 8), got);
                        cmp("price", rec_price, fld(b, 32, 4), got);
                    end
                    8'h45, 8'h58: cmp("shares", rec_shares, fld(b, 19, 4), got);
                    8'h43: begin
                        cmp("shares", rec_shares, fld(b, 19, 4), got);
                        cmp("price", rec_price, fld(b, 32, 4), got);
                    end
                    8'h55: begin
                        cmp("ref2", rec_ref2, fld(b, 19, 8), got);
                        cmp("shares", rec_shares, fld(b, 27, 4), got);
                        cmp("price", rec_price, fld(b, 31, 4), got);
                    end
                endcase
            end
            got++;
        end
        if (rec_err) begin
            if (errors < 10) $error("rec_err asserted at record %0d", got);
            errors++;
        end
    end

endmodule
