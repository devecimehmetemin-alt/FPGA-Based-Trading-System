`default_nettype none

module mold_deframe (
    input wire logic clk,
    input wire logic rst,
    input wire logic in_valid,            
    input wire logic [31:0] in_data,        
    input wire logic [3:0] in_keep,         
    input wire logic in_last,               
    input wire logic in_fcs_ok,
    output logic msg_valid,               
    output logic [31:0] msg_data,          
    output logic [3:0] msg_keep,      
    output logic msg_start,                 
    output logic msg_last,                  
    output logic [15:0] msg_len, // message length is 2 bytes
    output logic [63:0] msg_seq, // message sequence is 8 bytes
    output logic pkt_bad // in_fcs_ok = 0
);

    typedef enum logic [1:0] {S_HDR, S_LEN, S_BODY} state_t;
    // MoldUDP64: session[10] seq[8] count[2] then count x { len[2] body[len] }

    // clocked and combinational
    state_t state, st_n;                    
    logic [15:0] left, left_n; // bytes left in a state
    logic [15:0] len, len_n; // length of the message being emitted
    logic [63:0] seq, seq_n; // sequence of the current message
    logic [31:0] stage, stage_n; // output beat being filled up, 4 bytes
    logic [2:0] fill, fill_n; // bytes position already filled
    logic first, first_n; // msg_start

    function automatic logic [3:0] n_to_keep(input logic [2:0] n);
        case (n)                          
            3'd1: n_to_keep = 4'b0001;
            3'd2: n_to_keep = 4'b0011;
            3'd3: n_to_keep = 4'b0111;
            default: n_to_keep = 4'b1111;
        endcase
    endfunction

    assign pkt_bad = in_valid & in_last & ~in_fcs_ok;   

    always_comb begin
        logic [7:0] b; // the byte this loop iteration is processing

        st_n = state; // default everything to unchanged
        len_n = len;
        left_n = left; 
        seq_n = seq;
        stage_n = stage;
        fill_n = fill;
        first_n = first;
        msg_valid = 1'b0; 
        msg_data = 32'd0;
        msg_keep = 4'b1111;
        msg_start = 1'b0;
        msg_last = 1'b0;
        msg_len = len;
        msg_seq = seq;

        if (in_valid) begin
            for (int i = 0; i < 4; i++) begin 
                if (in_keep[i]) begin // skip unused lanes on the final beat
                    b = in_data[8*i +: 8]; // i = 0: b = in_data[7:0], etc
                    case (st_n)                     // st_n, not state: byte 1 sees byte 0's work
                        S_HDR: begin
                            if (left_n <= 16'd10 && left_n >= 16'd3) seq_n = {seq_n[55:0], b}; // 8 big-endian seq bytes
                            // header byte k is seen while left_n == 20-k, so the 8 sequence
                            // bytes (10..17) are left_n 10 down to 3.
                            left_n = left_n - 16'd1;
                            if (left_n == 16'd0) begin
                                st_n = S_LEN;
                                left_n = 16'd2; // next field is a 2-byte length
                            end
                        end
                        S_LEN: begin
                            len_n = {len_n[7:0], b}; 
                            left_n = left_n - 16'd1;
                            if (left_n == 16'd0) begin
                                st_n = S_BODY;
                                left_n = len_n; // body is len bytes
                                fill_n = 3'd0;  // start gathering at lane 0 
                                stage_n = 32'd0; // realignment
                                first_n = 1'b1;
                            end
                        end
                        S_BODY: begin
                            stage_n[8*fill_n +: 8] = b; // drop the byte into the next
                            fill_n = fill_n + 3'd1;         // free lane of the output beat
                            left_n = left_n - 16'd1;
                            if (fill_n == 3'd4 || left_n == 16'd0) begin
                                // emit when the beat is full, or the message ran out
                                msg_valid = 1'b1;
                                msg_data = stage_n;
                                msg_keep = n_to_keep(fill_n); // partial beat is partial keep
                                msg_start = first_n;
                                msg_last = (left_n == 16'd0);
                                msg_len = len_n;
                                msg_seq = seq_n; // read before the increment below
                                first_n = 1'b0;
                                fill_n = 3'd0;
                                stage_n = 32'd0; // reset stage for next beat
                                                                
                                if (left_n == 16'd0) begin
                                    seq_n = seq_n + 64'd1; // sequence number increased by 1 each message
                                    st_n = S_LEN; // assume another message follows, if not in_last guard resets to header
                                    left_n = 16'd2;
                                end
                            end
                        end
                        default: st_n = S_HDR;
                    endcase
                end
            end
            if (in_last) begin                  
                st_n = S_HDR;
                left_n = 16'd20;
                fill_n = 3'd0;
                first_n = 1'b1;
            end
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            state <= S_HDR;                 
            left <= 16'd20;                
            fill <= 3'd0;
            first <= 1'b1;
        end else begin
            state <= st_n;
            left <= left_n;
            fill <= fill_n;
            first <= first_n;
        end
        len <= len_n;
        seq <= seq_n;
        stage <= stage_n;
    end

endmodule

`default_nettype wire