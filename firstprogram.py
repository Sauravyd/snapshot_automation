
# num1 = str(input("Enter your name: "))
# print("Hello Welcome to Bootlabs,", num1)

# print("GitHub Copilot\nAI programming assistant\n5 years\nHello, Saurav! Welcome to Python.")

# if __name__ == "__main__":
#     print("GitHub Copilot\nAI programming assistant\n5 years\nHello, Saurav! Welcome to Python.")


# num = int(input("Enter a number: "))

# # if num % 2 == 0:
# #     print(num, "is an Even number")
# # else:
# #     print(num, "is an Odd number")


# # for i in range(1, 6):
# #     print("Hello", i)

# for i in range(1, 11):
#     print(num, "x", i, "=", num * i)

# project_tools = {"python": "3.17.1", "java": "3.1", "javascript": "ES6"}
# print(project_tools["javascript"])

import code
from itertools import count
import numbers
from tabnanny import check

from numpy import number


# def factorial(a):
#     if a == 0:
#         return 1
#     else:
#         return a * factorial(a-1)
# print(factorial(6))


# Create your own module with a function get_area() that calculates rectangle area.

# def get_area(length, width):
#     return length * width   

# print(get_area(5, 10))

# import json
# data = '{"name": "Saurav", "role": "DevOps"}'
# print(json.loads(data))
# parsed_data = json.loads(data)
# print(parsed_data["name"])
# print(parsed_data["role"]) 

# num1 = int(input("Enter first number: "))
# num2 = int(input("Enter second number: "))
# num3 = int(input("Enter third number: "))

# if (num1 >= num2) and (num1 >= num3):
#     print(num1, "is the largest number")
# elif (num2 >= num1) and (num2 >= num3):
#     print(num2, "is the largest number")
# else:
#     print(num3, "is the largest number")    





num = int(input("Enter a Number: "))

if num == 0 or num == 1:
    print(num," Not a prime  Number")
else:
    print(num, "a prime  Number")
    
    
prime number check code
is_prime = True
for i in range(2, int(num / 2) + 1):
    if num % i == 0:
        is_prime = False
        break       

if is_prime:
    print(num, "is a prime number")
else:
    print(num, "is not a prime number")
