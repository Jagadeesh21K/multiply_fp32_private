`timescale 1ns / 1ps

module multiply_fp32(
    input  wire        clk,
    input  wire        rst,
    input  wire        valid,      // one-cycle start pulse
    input  wire [31:0] a,
    input  wire [31:0] b,
    output reg  [31:0] z,
    output reg         out_valid   // one-cycle pulse when z is updated
);

    reg [31:0] a_r;
    reg [31:0] b_r;

    reg        busy;
    reg [2:0]  counter;

    reg        a_s;
    reg        b_s;
    reg        z_s;

    reg signed [10:0] a_e;
    reg signed [10:0] b_e;
    reg signed [10:0] z_e;
    reg signed [10:0] prod_e;      // raw exponent sum before the +1 alignment trick

    reg [23:0] a_m;
    reg [23:0] b_m;
    reg [23:0] z_m;

    reg [49:0] product;
    reg        guard_bit;
    reg        round_bit;
    reg        sticky;

    // small work regs used in the last two stages
    reg [24:0] rounded_work;
    reg signed [10:0] exp_work;
    reg [7:0]  biased_exp;

    // For subnormal results, rounding has to be done from the exact product.
    function automatic [31:0] pack_subnormal_exact;
        input        sign_i;
        input [49:0] product_i;
        input signed [10:0] prod_e_i;

        reg [63:0] product_ext;
        reg [63:0] shifted;
        reg [63:0] rounded;
        reg [63:0] mask;
        reg        local_guard;
        reg        local_sticky;
        integer    shift_amt;
        integer    k;
        begin
            product_ext = {14'd0, product_i};
            rounded     = 64'd0;

            // Result magnitude in subnormal units:
            // frac = round(product * 2^(prod_e + 101))
            k = prod_e_i + 101;

            if (k >= 0) begin
                if (k >= 64) begin
                    rounded = {64{1'b1}};
                end else begin
                    rounded = product_ext << k;
                end
            end else begin
                shift_amt = -k;

                if (shift_amt >= 64) begin
                    rounded = 64'd0;
                end else begin
                    shifted = product_ext >> shift_amt;

                    if (shift_amt == 0) begin
                        local_guard  = 1'b0;
                        local_sticky = 1'b0;
                    end else begin
                        local_guard = product_ext[shift_amt - 1];

                        if (shift_amt == 1) begin
                            local_sticky = 1'b0;
                        end else begin
                            mask         = (64'd1 << (shift_amt - 1)) - 64'd1;
                            local_sticky = |(product_ext & mask);
                        end
                    end

                    rounded = shifted;
                    if (local_guard && (local_sticky || shifted[0])) begin
                        rounded = rounded + 64'd1;
                    end
                end
            end

            // If subnormal rounding carries into bit 23, it becomes the minimum normal.
            if (rounded >= 64'h0000_0000_0080_0000) begin
                pack_subnormal_exact = {sign_i, 8'd1, 23'd0};
            end else begin
                pack_subnormal_exact = {sign_i, 8'd0, rounded[22:0]};
            end
        end
    endfunction

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            a_r          <= 32'd0;
            b_r          <= 32'd0;
            z            <= 32'd0;
            out_valid    <= 1'b0;

            busy         <= 1'b0;
            counter      <= 3'd0;

            a_s          <= 1'b0;
            b_s          <= 1'b0;
            z_s          <= 1'b0;

            a_e          <= 11'sd0;
            b_e          <= 11'sd0;
            z_e          <= 11'sd0;
            prod_e       <= 11'sd0;

            a_m          <= 24'd0;
            b_m          <= 24'd0;
            z_m          <= 24'd0;

            product      <= 50'd0;
            guard_bit    <= 1'b0;
            round_bit    <= 1'b0;
            sticky       <= 1'b0;

            rounded_work <= 25'd0;
            exp_work     <= 11'sd0;
            biased_exp   <= 8'd0;
        end else begin
            out_valid <= 1'b0;

            // Only accept a new request when the block is idle.
            if (!busy) begin
                if (valid) begin
                    a_r     <= a;
                    b_r     <= b;
                    busy    <= 1'b1;
                    counter <= 3'd1;
                end
            end else begin
                case (counter)

                    // Stage 1: unpack fields
                    3'd1: begin
                        a_s <= a_r[31];
                        b_s <= b_r[31];

                        a_e <= $signed({3'b000, a_r[30:23]}) - 11'sd127;
                        b_e <= $signed({3'b000, b_r[30:23]}) - 11'sd127;

                        a_m <= {1'b0, a_r[22:0]};
                        b_m <= {1'b0, b_r[22:0]};

                        counter <= 3'd2;
                    end

                    // Stage 2: add the hidden 1 for normal inputs
                    3'd2: begin
                        if (a_r[30:23] != 8'd0) begin
                            a_m[23] <= 1'b1;
                        end else begin
                            a_e <= -11'sd126;
                        end

                        if (b_r[30:23] != 8'd0) begin
                            b_m[23] <= 1'b1;
                        end else begin
                            b_e <= -11'sd126;
                        end

                        counter <= 3'd3;
                    end

                    // Stage 3: tiny normalization step
                    3'd3: begin
                        if (!a_m[23] && (a_m != 24'd0)) begin
                            a_m <= a_m << 1;
                            a_e <= a_e - 11'sd1;
                        end

                        if (!b_m[23] && (b_m != 24'd0)) begin
                            b_m <= b_m << 1;
                            b_e <= b_e - 11'sd1;
                        end

                        counter <= 3'd4;
                    end

                    // Stage 4: core multiply
                    3'd4: begin
                        z_s    <= a_s ^ b_s;
                        prod_e <= a_e + b_e;
                        z_e    <= a_e + b_e + 11'sd1;
                        product <= a_m * b_m * 2'd4;

                        counter <= 3'd5;
                    end

                    // Stage 5: pull out mantissa and round bits
                    3'd5: begin
                        z_m       <= product[49:26];
                        guard_bit <= product[25];
                        round_bit <= product[24];
                        sticky    <= |product[23:0];

                        counter <= 3'd6;
                    end

                    // Stage 6: normalize the mantissa window
                    3'd6: begin
                        if (z_m[23]) begin
                            z_m       <= z_m;
                            guard_bit <= guard_bit;
                            round_bit <= round_bit;
                            sticky    <= sticky;
                            z_e       <= z_e;
                        end else begin
                            z_m       <= product[48:25];
                            guard_bit <= product[24];
                            round_bit <= product[23];
                            sticky    <= |product[22:0];
                            z_e       <= z_e - 11'sd1;
                        end

                        counter <= 3'd7;
                    end

                    // Stage 7: round and pack
                    3'd7: begin
                        if (z_e >= -11'sd126) begin
                            rounded_work = {1'b0, z_m};
                            exp_work     = z_e;

                            // round-to-nearest-even
                            if (guard_bit && (round_bit || sticky || z_m[0])) begin
                                rounded_work = rounded_work + 25'd1;
                            end

                            // carry from rounding bumps the exponent
                            if (rounded_work[24]) begin
                                rounded_work = rounded_work >> 1;
                                exp_work     = exp_work + 11'sd1;
                            end

                            if (exp_work > 11'sd127) begin
                                z <= {z_s, 8'hFF, 23'd0};
                            end else begin
                                biased_exp = exp_work + 11'sd127;
                                z <= {z_s, biased_exp, rounded_work[22:0]};
                            end
                        end else begin
                            z <= pack_subnormal_exact(z_s, product, prod_e);
                        end

                        out_valid <= 1'b1;
                        busy      <= 1'b0;
                        counter   <= 3'd0;
                    end

                    default: begin
                        busy      <= 1'b0;
                        counter   <= 3'd0;
                        out_valid <= 1'b0;
                    end
                endcase
            end
        end
    end

endmodule